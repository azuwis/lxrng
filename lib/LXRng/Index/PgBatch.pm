package LXRng::Index::PgBatch;

# Specialized subclass of LXRng::Index::Pg for doing parallelized
# batched inserts into database.  Higher performance (and higher
# complexity).

use strict;
use DBI;
use POSIX qw(:sys_wait_h);

use base qw(LXRng::Index::Pg);


sub transaction {
    my ($self, $code) =  @_;

    if ($self->dbh->{AutoCommit}) {
	$self->dbh->{AutoCommit} = 0;
	$self->dbh->do(q(set constraints all deferred));
	$code->();
	$self->flush();
	$self->dbh->commit();
	$self->dbh->{AutoCommit} = 1;

	# At end of outermost transaction, wait for outstanding flushes
	$self->_flush_wait();
    }
    else {
	# If we're in a transaction already, don't return to
	# AutoCommit state.
	$code->();

	# Only occasional synchronization if we're inside another
	# transaction.
	if ($self->{'writes'}++ % 491 == 0) {
	    $self->flush();
	    $self->dbh->commit();
	}
    }
}

sub new {
    my ($class, @args) = @_;

    my $self = $class->SUPER::new(@args);
    $$self{'writes'} = 0;
    $$self{'rows'} = 0;

    return $self;
}

sub flush {
    my ($self) = @_;

    return unless exists($$self{'cache'});

    $self->_flush_wait();

    my $pre = $self->prefix;
    $self->dbh->commit() unless $self->dbh->{AutoCommit};
    my $pid = open($$self{'flush_pipe'}, "-|");
    die("fork failed: $!") unless defined($pid);
    if ($pid == 0) {
	$SIG{'INT'}  = 'IGNORE';
	$SIG{'QUIT'} = 'IGNORE';
	$SIG{'TERM'} = 'IGNORE';
	$SIG{'PIPE'} = 'IGNORE';
	undef $$self{'flush_pipe'};

	my $i = 0;
	my $cache = $$self{'cache'};
	$$self{'dbh'}->{InactiveDestroy} = 1 if $$self{'dbh'};
	undef $$self{'cache'};
	undef $$self{'dbh'};
	foreach my $table (qw(symbols identifiers usage includes)) {
	    if (exists($$cache{$table})) {
		$self->dbh->do(qq{copy $pre$table from stdin});
		foreach my $l (@{$$cache{$table}}) {
		    $i++;
		    $self->dbh->pg_putline($l);
		}
		$self->dbh->pg_endcopy;
	    }
	}
	$self->dbh->commit() unless $self->dbh->{AutoCommit};
	# Analyze after first 50k rows, then for every 3M row.
	$self->dbh->do(q(analyze)) if
	    (($$self{'rows'} % 3000000) + $i > 3000000) or
	    (($$self{'rows'} < 50000) and ($$self{'rows'} + $i > 50000));

	$self->dbh->disconnect();
	print("$i\n");
	close(STDOUT);
	kill(9, $$);
    }
    $$self{'flush_pid'} = $pid;
    foreach my $table (%{$$self{'cache'}}) {
	@{$$self{'cache'}{$table}} = ();
    }
    %{$$self{'cache'}} = ();
    delete($$self{'cache'});

    warn "*** index: flushing in background\n";
}

sub _flush_wait {
    my ($self) = @_;

    return unless $$self{'flush_pipe'};

    warn "*** index: waiting for running flush to complete...\n";
    $self->dbh->commit() unless $self->dbh->{AutoCommit};
    my $rows;
    if (sysread($$self{'flush_pipe'}, $rows, 1024) > 0) {
	$rows += 0;
	$$self{'rows'} += $rows;
	warn "*** index: flushed $rows rows\n";
    }
    $$self{'flush_pipe'}->close();
    undef $$self{'flush_pipe'};
    waitpid($$self{'flush_pid'}, 0);
}

sub _cache {
    my ($self, $name) = @_;

    $$self{'cache'}{$name} ||= [];
    return $$self{'cache'}{$name};
}

sub _cached_seqno {
    my ($self, $seqname) = @_;

   unless (exists($$self{'cached_seqno'}{$seqname}) and
	$$self{'cached_seqno'}{$seqname}{'min'} <=
	$$self{'cached_seqno'}{$seqname}{'max'})
    {
	my $dbh = $self->dbh;
	my $pre = $self->prefix;
	my $sth = $$self{'sth'}{'_cached_seqno'}{$seqname} ||=
	    $dbh->prepare(qq{select setval('$pre$seqname',
					   nextval('$pre$seqname')+1000)});
	$sth->execute();
	my ($id) = $sth->fetchrow_array();
	$sth->finish();
	$$self{'cached_seqno'}{$seqname}{'min'} = $id-1000;
	$$self{'cached_seqno'}{$seqname}{'max'} = $id;
    }

    return $$self{'cached_seqno'}{$seqname}{'min'}++;
}

sub _add_include {
    my ($self, $file_id, $inc_id) = @_;

    push(@{$self->_cache('includes')}, "$file_id\t$inc_id\n");

    return 1;
}

sub _prime_symbol_cache {
    my ($self) = @_;

    my $dbh = $self->dbh;
    my $pre = $self->prefix;
    my $sth = $$self{'sth'}{'_prime_symbol_cache'} ||=
	$dbh->prepare(qq{select name, id from ${pre}symbols});
    $sth->execute();
    my %cache;
    while (my ($name, $id) = $sth->fetchrow_array()) {
	$cache{$name} = $id;
    }
    $sth->finish;
    
    $$self{'__symbol_cache'} = \%cache;
}

sub _add_usage {
    my ($self, $file_id, $symbol_id, $lines) = @_;
    
    push(@{$self->_cache('usage')},
	 "$file_id\t$symbol_id\t\{".join(",", @$lines)."}\n");

    return 1;
}

sub _add_symbol {
    my ($self, $symbol) = @_;

    my $id = $self->_cached_seqno('symnum');
    push(@{$self->_cache('symbols')}, "$id\t$symbol\n");

    $self->_prime_symbol_cache()
	unless exists $$self{'__symbol_cache'};

    $$self{'__symbol_cache'}{$symbol} = $id;

    return $id;
}

sub _add_ident {
    my ($self, $rfile_id, $line, $sym_id, $type, $ctx_id) = @_;

    $ctx_id = '\\N' unless defined($ctx_id);

    my $id = $self->_cached_seqno('identnum');
    push(@{$self->_cache('identifiers')}, join("\t", $id, $sym_id,
					       $rfile_id, $line, $type,
					       $ctx_id)."\n");

    return $id;
}

my $_get_symbol_usage = 0;
sub _get_symbol {
    my ($self, $symbol) = @_;

    unless (exists($$self{'__symbol_cache'})) {
	# Only prime the cache once it's clear that we're likely to
	# hit it a significant number of times.
	return $self->SUPER::_get_symbol($symbol) if
	    $_get_symbol_usage++ < 100;

	$self->_prime_symbol_cache();
    }

    return $$self{'__symbol_cache'}{$symbol} if
	exists $$self{'__symbol_cache'}{$symbol};
    
    return undef;
}

sub _prime_fileid_cache {
    my ($self) = @_;

    my $dbh = $self->dbh;
    my $pre = $self->prefix;
    my $sth = $$self{'sth'}{'_prime_fileid_cache'} ||=
	$dbh->prepare(qq{select path, id from ${pre}files});
    $sth->execute();
    my %cache;
    while (my ($name, $id) = $sth->fetchrow_array()) {
	$cache{$name} = $id;
    }
    $sth->finish;
    
    $$self{'__fileid_cache'} = \%cache;
}

sub _add_file {
    my ($self, $path) = @_;

    my $id = $self->SUPER::_add_file($path);
    $self->_prime_fileid_cache()
	unless exists $$self{'__fileid_cache'};

    $$self{'__fileid_cache'}{$path} = $id;

    return $id;
}

my $_get_file_usage = 0;
sub _get_file {
    my ($self, $path) = @_;

    unless (exists($$self{'__fileid_cache'})) {
	return $self->SUPER::_get_file($path) if
	    $_get_file_usage++ < 500;

	$self->_prime_fileid_cache();
    }

    return $$self{'__fileid_cache'}{$path} if
	exists $$self{'__fileid_cache'}{$path};
    
    return undef;
}

sub DESTROY {
    my ($self) = @_;

    if ($$self{'dbh'} and ($$self{'dbh_pid'} != $$)) {
	# Don't flush or disconnect inherited db handle.
	$$self{'dbh'}->{InactiveDestroy} = 1;
	undef $$self{'dbh'};
	return;
    }

    if ($$self{'writes'} > 0) {
	$self->flush();
	$self->_flush_wait();
    }

    if ($$self{'dbh'}) {
	$$self{'dbh'}->rollback() unless $$self{'dbh'}{'AutoCommit'};
	$$self{'dbh'}->disconnect();
	delete($$self{'dbh'});
    }
}

1;
