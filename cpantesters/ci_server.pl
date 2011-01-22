#!/usr/bin/perl
use strict; use warnings;

# Controls a fleet of ci bots smoking CPAN

# TODO list:
#	- use SimpleDBI

use POE;
use POE::Component::Server::SimpleHTTP;
use POE::Component::SmokeBox::Dists 1.02;	# include the pkg_time param
use POE::Component::IRC::State 6.18;		# 6.18 depends on POE::Filter::IRCD 2.42 to shutup warnings about 005 numerics
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::BotCommand;
use base 'POE::Session::AttributeBased';

use DBI;
use YAML::Tiny;

# Set some handy variables
my $ircnick = 'CI-Server';
my $ircserver = '192.168.0.200';
my $port = 11_112;
my $dsn = 'dbi:SQLite:dbname=/home/cpan/ci_server.db';
my $user = 'ci';
my $pass = 'ci';

POE::Session->create(
	__PACKAGE__->inline_states(),
);

POE::Kernel->run;
exit 0;

sub _parent : State {}
sub _child : State {}

sub _start : State {
	$_[KERNEL]->alias_set( 'CI-Server' );

	# setup our stuff
	$_[KERNEL]->yield( 'create_db' );
	$_[KERNEL]->yield( 'create_irc' );
	$_[KERNEL]->yield( 'create_http' );

	return;
}

sub create_db : State {
	# connect to the db
	my $dbh = DBI->connect( $dsn, $user, $pass ) or die $DBI::errstr, "\n";
	$_[HEAP]->{'DBH'} = $dbh;

	# Set some sqlite optimizations
	if ( $dsn =~ /^dbi\:SQLite/i ) {
		$dbh->do(qq{PRAGMA synchronous = OFF}) or die $dbh->errstr;
	}

	# Do we have our table created yet?
	my $sql = 'CREATE TABLE IF NOT EXISTS ci ( hostname TEXT, done INTEGER, block INTEGER, UNIQUE(hostname) )';
	$dbh->do( $sql ) or die $dbh->errstr;

	return;
}

sub create_http : State {
	POE::Component::Server::SimpleHTTP->new(
		'ALIAS'         =>      'HTTPD',
		'PORT'          =>      $port,
		'HOSTNAME'      =>      'ciserver.com',
		'HANDLERS'      =>      [
			{
				'DIR'           => '^/CI/start/.+',
				'SESSION'	=> 'CI-Server',
				'EVENT'         => 'ci_start',
			},
			{
				'DIR'           => '^/CI/done/.+/.+',
				'SESSION'	=> 'CI-Server',
				'EVENT'         => 'ci_done',
			},
			{
				'DIR'		=> '.*',
				'SESSION'	=> 'CI-Server',
				'EVENT'		=> 'ci_404',
			},
		],
	) or die 'Unable to create the HTTP Server';

	return;
}

sub create_irc : State {
	# create the IRC bot
	$_[HEAP]->{'IRC'} = POE::Component::IRC::State->spawn(
		nick	=> $ircnick,
		ircname	=> $ircnick,
		server	=> $ircserver,
#		Flood	=> 1,
	) or die "Unable to spawn irc: $!";

	$_[HEAP]->{'IRC'}->plugin_add( 'AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => { '#smoke' => '' } ) );
	$_[HEAP]->{'IRC'}->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new() );
	$_[HEAP]->{'IRC'}->plugin_add( 'BotCommand', POE::Component::IRC::Plugin::BotCommand->new(
		Commands	=> {
			'status'	=> 'Returns information about the CI server. Takes no arguments.',
			'uname'		=> 'Returns the uname of the machine. Takes no arguments.',
			'time'		=> 'Returns the local time of the machine. Takes no arguments.',
			'df'		=> 'Returns the free space of the machine. Takes no arguments.',
		},
		Addressed	=> 0,
		Ignore_unknown	=> 1,
		Prefix		=> '!',
		In_channels	=> 1,
		In_private	=> 1,
		Eat		=> 1,
	) );

	$_[HEAP]->{'IRC'}->yield( 'connect' => {} );

	return;
}

sub irc_msg : State {
	# Sent whenever you receive a PRIVMSG command that was addressed to you privately. ARG0 is the nick!hostmask of the sender. ARG1 is an array
	# reference containing the nick(s) of the recipients. ARG2 is the text of the message.
	my( $nickhost, $recipients, $msg ) = @_[ARG0 .. ARG2];
	return;
}

sub irc_public : State {
	# Sent whenever you receive a PRIVMSG command that was sent to a channel. ARG0 is the nick!hostmask of the sender. ARG1 is an array reference
	# containing the channel name(s) of the recipients. ARG2 is the text of the message.
	my( $nickhost, $channels, $msg ) = @_[ARG0 .. ARG2];
	return;
}

sub irc_botcmd_time : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	my $time = time;

	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Time: $time (" . localtime($time) . ")" );

	return;
}

sub irc_botcmd_df : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	my $df = dfportable( $ENV{HOME} );
	if ( defined $df ) {
		my $free = format_bytes( $df->{'bavail'}, si => 1 );
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Df: $free" );
	} else {
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Df: Error in getting df!" );
	}

	return;
}

sub irc_botcmd_uname : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	# Load the config info
	require POSIX;
	my $uname = join( ' ', POSIX::uname() );
	chomp( $uname );

	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Uname: $uname" );

	return;
}

sub irc_botcmd_status : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	# Get the number of smokers
	my @results;
	my $sql = 'SELECT hostname FROM ci';
	my $sth = $_[HEAP]->{'DBH'}->prepare_cached( $sql ) or die $DBI::errstr, "\n";
	$sth->execute();
	while ( my $row = $sth->fetchrow_hashref() ) {
		push @results, { %{ $row } };
	}

	# TODO expose more data?
	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "CI Server ONLINE - bots running: " . scalar @results );

	return;
}

sub ci_done : State {
	# ARG0 = HTTP::Request object, ARG1 = HTTP::Response object, ARG2 = the DIR that matched
	my( $request, $response, $dirmatch ) = @_[ ARG0 .. ARG2 ];
	my( $hostname, $block, $duration ) = ( split m#/#, $request->uri->path )[3 .. 5];

#	warn "New DONE req: " . $request->uri->path;

	# Verify this user
	my @results;
	my $sql = 'SELECT done, block FROM ci WHERE hostname = ?';
	my $sth = $_[HEAP]->{'DBH'}->prepare_cached( $sql ) or die $DBI::errstr, "\n";
	$sth->execute( $hostname ) or die "Unable to get DB done data => " . $sth->errstr;
	while ( my $row = $sth->fetchrow_hashref() ) {
		push @results, { %{ $row } };
	}

#	use Data::Dumper;
#	warn Dumper( "DB RESULT ($hostname)", \@results );

	if ( scalar @results ) {
		# Sanity checks
		if ( $results[0]->{block} ne $block ) {
			$response->code( 404 );
			$response->content( 'invalid block' );
			$_[KERNEL]->post( 'HTTPD', 'DONE', $response );
			return;
		}
		if ( $results[0]->{done} == 1 ) {
			$response->code( 404 );
			$response->content( 'invalid done code' );
			$_[KERNEL]->post( 'HTTPD', 'DONE', $response );
			return;
		}
	} else {
		$response->code( 404 );
		$response->content( 'invalid client' );
		$_[KERNEL]->post( 'HTTPD', 'DONE', $response );
		return;
	}

	# Update the DB
	$sql = 'UPDATE ci SET done = 1 WHERE hostname = ?';
	$sth = $_[HEAP]->{'DBH'}->prepare_cached( $sql ) or die $DBI::errstr, "\n";
	my $rv = $sth->execute( $hostname ) or die "Unable to update DB done status => " . $sth->errstr;
	if ( $rv != 1 ) {
		die "Failed to update DB done status for $hostname";
	}

	# Did the bot smoke the entire CPAN?
	if ( ! defined block2char( $block + 1 ) ) {
		# TODO gather statistics so we can display entire CPAN smoke duration?
		$_[HEAP]->{'IRC'}->yield( privmsg => '#smoke', "Botsnack time! Bot( $hostname ) smoked the entire CPAN!" );
	}

	# TODO archive this run for statistical analysis? ( use the duration received from the client, anything else?

	# encode it in the basic yaml format
	my $string;
	eval { $string = YAML::Tiny::Dump( {
		result => 1,
		block2char => uc( block2char( $results[0]->{'block'} ) ),
	} ); };

	# Do our stuff to HTTP::Response
	$response->header( 'Content-Type' => 'application/x-yaml; charset=utf-8' );
	$response->code( 200 );
	$response->content( $string );

	# We are done!
	$_[KERNEL]->post( 'HTTPD', 'DONE', $response );
	return;
}

sub ci_start : State {
	# ARG0 = HTTP::Request object, ARG1 = HTTP::Response object, ARG2 = the DIR that matched
	my( $request, $response, $dirmatch ) = @_[ ARG0 .. ARG2 ];
	my $hostname = ( split m#/#, $request->uri->path )[3];

#	warn "New START req: " . $request->uri->path;

	# get the block + result
	my @results;
	my $sql = 'SELECT block, done FROM ci WHERE hostname = ?';
	my $sth = $_[HEAP]->{'DBH'}->prepare_cached( $sql ) or die $DBI::errstr, "\n";
	$sth->execute( $hostname ) or die "Unable to get DB block => " . $sth->errstr;
	while ( my $row = $sth->fetchrow_hashref() ) {
		push @results, { %{ $row } };
	}

#	use Data::Dumper;
#	warn Dumper( "DB RESULT ($hostname)", \@results );

	# Do we have a record?
	my $res = {};
	if ( scalar @results ) {
		if ( ! $results[0]->{'done'} ) {
			# Bad news, client requested a new block before completing the previous one!
			$_[HEAP]->{'IRC'}->yield( privmsg => '#smoke', "WARNING: Bot( $hostname ) is malformed, requested a new block without completing the old one!" );
		}

		# Move on to the next block
		$res->{'block'} = $results[0]->{'block'} + 1;
		if ( ! defined block2char( $res->{'block'} ) ) {
			# finished the entire block list, start over
			$res->{'block'} = 0;
			$res->{'finished'} = 1;
		}
		$sql = 'UPDATE ci SET block = ?, done = 0 WHERE hostname = ?';
		$sth = $_[HEAP]->{'DBH'}->prepare_cached( $sql ) or die $DBI::errstr, "\n";
		my $rv = $sth->execute( $res->{'block'}, $hostname ) or die "Unable to update DB block status => " . $sth->errstr;
		if ( $rv != 1 ) {
			die "Failed to update DB status for $hostname";
		}
	} else {
		# Completely new smoker, start at the beginning!
		$res->{block} = 0;
		$sql = 'INSERT INTO ci ( block, done, hostname ) VALUES ( ?, 0, ? )';
		$sth = $_[HEAP]->{'DBH'}->prepare_cached( $sql ) or die $DBI::errstr, "\n";
		$sth->execute( $res->{'block'}, $hostname ) or die "Unable to insert DB status => " . $sth->errstr;
	}

	# search for the block's data!
	POE::Component::SmokeBox::Dists->distro(
		'search'	=> build_regex( $res->{'block'} ),
		'event'		=> 'search_results',
		'url'		=> "ftp://$ircserver/CPAN/",	# TODO this is hardcoded...
		'_response'	=> $response,
		'_data'		=> $res,
	);

	return;
}

sub search_results : State {
	my $ref = $_[ARG0];

	die $ref->{'error'} if $ref->{'error'};

	# Finalize the result!
	my $result = {
		block => $ref->{'_data'}->{'block'},
		block2char => uc( block2char( $ref->{'_data'}->{'block'} ) ),
		dists => $ref->{'dists'},
		( exists $ref->{'_data'}->{'finished'} ? ( 'purge' => 1 ) : () ),
	};

	# encode it in the basic yaml format
	my $string;
	eval { $string = YAML::Tiny::Dump( $result ); };

	# Do our stuff to HTTP::Response
	$ref->{'_response'}->header( 'Content-Type' => 'application/x-yaml; charset=utf-8' );
	$ref->{'_response'}->code( 200 );
	$ref->{'_response'}->content( $string );

	# We are done!
	$_[KERNEL]->post( 'HTTPD', 'DONE', $ref->{'_response'} );
	return;
}

sub block2char {
	my $block = shift;

#apoc@blackhole:~/Desktop/mystuff$ perl cpan_frequency.pl
#Frequency of CPAN distributions by name ( Jan 20, 2011 )
# 0 - 0
# z - 34
# q - 57
# y - 65
# v - 167
# j - 173
# u - 185
# k - 213
# o - 254
# e - 411
# r - 468
# i - 499
# x - 509
# h - 671
# b - 691
# f - 728
# g - 804
# l - 839
# n - 1074
# w - 1170
# s - 1278
# m - 1464
# p - 1692
# d - 1915
# a - 2006
# t - 2049
# c - 2390

	# We work from smallest to largest in the hope of spreading the dependencies around...
	my @chars = qw( 0 z q y v j u k o e r i x h b f g l n w s m p d a t c );
	return $chars[ $block ];
}

sub build_regex {
	my $block = shift;
	my $sel = block2char( $block );
	if ( $sel eq '0' ) {
		return '^[^[:alpha:]]';
	} else {
		return '^(' . $sel . '|' . uc( $sel ) . ')';
	}
}

sub ci_404 : State {
	# ARG0 = HTTP::Request object, ARG1 = HTTP::Response object, ARG2 = the DIR that matched
	my( $request, $response, $dirmatch ) = @_[ ARG0 .. ARG2 ];

	warn "Erroneous request: " . $request->uri->path . "\n";

	# Check for errors
	if ( ! defined $request ) {
		$_[KERNEL]->post( 'HTTPD', 'DONE', $response );
		return;
	}

	# Do our stuff to HTTP::Response
	$response->code( 404 );
	$response->content( '' );

	# We are done!
	$_[KERNEL]->post( 'HTTPD', 'DONE', $response );
	return;
}
