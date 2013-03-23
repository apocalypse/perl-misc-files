#!/usr/bin/perl
#
# TODO
#  - periodically execute sqlite purge or something like that to clean up the db?

# File taken from examples/moo.pl in the relay server dist
use strict; use warnings;

use POE;
use POE::Component::Metabase::Relay::Server 0.18;	# needed for recv_event support
use POE::Component::IRC::State 6.18;			# 6.18 depends on POE::Filter::IRCD 2.42 to shutup warnings about 005 numerics
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::BotCommand;
use base 'POE::Session::AttributeBased';

use Number::Bytes::Human qw( format_bytes );
use Filesys::DfPortable;

# Set some handy variables
my $ircnick = 'relayd';
my $ircserver = 'cpan.0ne.us';
my $ircpass = 'apoc4cpan';
my $relayd_port = 11_111;
my $metabase_id = '/home/cpan/.metabase/id.json';	# TODO why doesn't ~/.metabase work?
my $metabase_dsn = 'dbi:SQLite:dbname=/home/cpan/CPANTesters.db';
my $metabase_uri = 'https://metabase.cpantesters.org/api/v1/';
my $metabase_norelay = 1;

POE::Session->create(
	__PACKAGE__->inline_states(),
);

POE::Kernel->run;
exit 0;

sub _start : State {
	$_[KERNEL]->alias_set( 'Metabase-Relay' );

	# setup our stuff
	$_[KERNEL]->yield( 'create_relay' );
	$_[KERNEL]->yield( 'create_irc' );

	return;
}

sub _child : State {
	return;
}

sub _stop : State {
	$_[HEAP]->{'IRC'}->shutdown();
	$_[HEAP]->{'relayd'}->shutdown();
	return;
}

sub create_relay : State {
	my $test_httpd = POE::Component::Metabase::Relay::Server->spawn(
		port		=> $relayd_port,
		id_file		=> $metabase_id,
		dsn		=> $metabase_dsn,
		uri		=> $metabase_uri,
		debug		=> 0,
		multiple	=> 1,
		no_relay	=> $metabase_norelay,
		submissions	=> 2,
		recv_event	=> 'relayd_gotreport',
	);

	$_[HEAP]->{'relayd'} = $test_httpd;

	# TODO ugly code here
	$_[KERNEL]->delay( '_relayd_createtable', 1 );
	return;
}

# Create the report cache if it doesn't exist
sub _relayd_createtable : State {
	$_[HEAP]->{'relayd'}->queue->_easydbi->do(
		sql => 'CREATE TABLE IF NOT EXISTS reports ( osversion TEXT, distfile TEXT, archname TEXT, textreport TEXT, osname TEXT, perl_version TEXT, grade TEXT, ip TEXT )',
		event => '_got_create',
	);

	return;
}

sub _got_create : State {
	my $result = $_[ARG0];

	if ( exists $result->{error} ) {
		die "Error in creating report table: $result->{error}";
	}

	return;
}

sub relayd_gotreport : State {
	my( $data, $ip ) = @_[ARG0,ARG1];

	# grab the proper perl version / vm name from the report
        my $perl_ver;
        if ( $data->{textreport} =~ /PERL_CPANSMOKER_HOST=\"(.+)\"/ ) {
                $perl_ver = $1 . " / " . $data->{osname} . "(" . $data->{archname} . ")";
        } else {
		$perl_ver = $data->{perl_version} . " / " . $data->{osname} . "(" . $data->{archname} . ")";
        }

	# TODO colorize it?
	$_[HEAP]->{'IRC'}->yield( privmsg => '#smoke-reports',
		uc( $data->{grade} ) . " [" . $data->{distfile} . "] $perl_ver"
	);

	# Store it!
	# TODO ugly code here
	$_[HEAP]->{'relayd'}->queue->_easydbi->insert(
		sql => 'INSERT INTO reports ( osversion, distfile, archname, textreport, osname, perl_version, grade, ip ) VALUES ( ?, ?, ?, ?, ?, ?, ?, ? )',
		placeholders => [ $data->{osversion}, $data->{distfile}, $data->{archname}, $data->{textreport}, $data->{osname}, $data->{perl_version}, $data->{grade}, $ip ],
		event => '_got_report',
	);

	return;
}

sub _got_report : State {
	my $result = $_[ARG0];

	if ( exists $result->{error} ) {
		die "Error in storing report: $result->{error}";
	}

	return;
}

sub create_irc : State {
	# create the IRC bot
	$_[HEAP]->{'IRC'} = POE::Component::IRC::State->spawn(
		nick	=> $ircnick,
		ircname	=> $ircnick,
		server	=> $ircserver,
		Password => $ircpass,
		Flood	=> 1,
	) or die "Unable to spawn irc: $!";

	$_[HEAP]->{'IRC'}->plugin_add( 'AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => { '#smoke' => '', '#smoke-reports' => '' } ) );
	$_[HEAP]->{'IRC'}->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new() );
	$_[HEAP]->{'IRC'}->plugin_add( 'BotCommand', POE::Component::IRC::Plugin::BotCommand->new(
		Commands	=> {
			'status'	=> 'Returns information about the relayd queue. Takes no arguments.',
			'uname'		=> 'Returns the uname of the machine. Takes no arguments.',
			'time'		=> 'Returns the local time of the machine. Takes no arguments.',
			'df'		=> 'Returns the free space of the machine. Takes no arguments.',
			'relay'		=> 'Get/Set the status of the relayd. Takes one optional argument: a bool value.',
			'parallel'	=> 'Get/Set the number of parallel HTTP clients for report uploads. Takes one optional argument: an int value.',
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

	# TODO ugly code here
	$_[HEAP]->{'relayd'}->queue->_easydbi->arrayhash(
		sql => 'SELECT count(*) AS count from queue',
		event => '_got_status',
		_where => $where,
	);

	return;
}

sub _got_status : State {
	my $result = $_[ARG0];

#	$VAR1 = {
#          'sql' => 'SELECT count(*) AS count from queue',
#          'rows' => 1,
#          'event' => '_got_queuecount',
#          'placeholders' => [],
#          'session' => 2,
#          'action' => 'arrayhash',
#          'id' => 1,
#          '_where' => '#smoke',
#          'result' => [
#                        {
#                          'count' => 117
#                        }
#                      ]
#        };

	my $status = $_[HEAP]->{'relayd'}->no_relay ? 'DISABLED' : 'ENABLED';
	if ( exists $result->{error} ) {
		$_[HEAP]->{'IRC'}->yield( privmsg => $result->{'_where'}, "RELAYING $status: Error in getting queued reports: " . $result->{error} );
	} else {
		$_[HEAP]->{'IRC'}->yield( privmsg => $result->{'_where'}, "RELAYING $status: Number of reports in the queue: " . $result->{result}->[0]->{'count'} );
	}

	return;
}

sub irc_botcmd_relay : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	if ( defined $arg ) {
		if ( $arg =~ /^(?:0|1)$/ ) {
			# semantics is reversed from relayd, ha!
			if ( $_[HEAP]->{'relayd'}->no_relay ) {
				if ( $arg ) {
					$_[HEAP]->{'relayd'}->no_relay( 0 );
					$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Enabling the relayer...' );
				} else {
					$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Relaying was already disabled!' );
				}
			} else {
				if ( $arg ) {
					$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Relaying was already enabled!' );
				} else {
					$_[HEAP]->{'relayd'}->no_relay( 1 );
					$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Disabling the relayer...' );
				}
			}
		} else {
			$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Invalid argument - it must be 0 or 1' );
		}
	} else {
		my $status = $_[HEAP]->{'relayd'}->no_relay ? 'DISABLED' : 'ENABLED';
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Relayd status: $status" );
	}

	return;
}

sub irc_botcmd_parallel : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	if ( defined $arg ) {
		if ( $arg =~ /^\d+$/ ) {
			$_[HEAP]->{'relayd'}->submissions( $arg );
			$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Setting parallel HTTP clients to: $arg" );
		} else {
			$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Invalid argument - it must be an integer' );
		}
	} else {
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Relayd parallel HTTP clients: " . $_[HEAP]->{'relayd'}->submissions );
	}

	return;
}
