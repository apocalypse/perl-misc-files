#!/usr/bin/perl
# File taken from examples/moo.pl in the relay server dist
use strict; use warnings;

use POE;
use POE::Component::Metabase::Relay::Server 0.06;	# Needed to fix numerous SQL bugs
use POE::Component::IRC::State 6.18;			# 6.18 depends on POE::Filter::IRCD 2.42 to shutup warnings about 005 numerics
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::BotCommand;
use base 'POE::Session::AttributeBased';

use Number::Bytes::Human qw( format_bytes );
use Filesys::DfPortable;

# Set some handy variables
my $ircnick = 'relayd';
my $ircserver = '192.168.0.200';
my $relayd_port = 11_111;
my $metabase_id = '/home/cpan/.metabase/id.json';
my $metabase_dsn = 'dbi:SQLite:dbname=/home/cpan/CPANTesters.db';
my $metabase_uri = 'https://metabase.cpantesters.org/beta/';

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
		port	=> $relayd_port,
		id_file	=> $metabase_id,
		dsn	=> $metabase_dsn,
		uri	=> $metabase_uri,
		debug	=> 1,
		multiple=> 1,
		no_relay=> 1,
	);

	$_[HEAP]->{'relayd'} = $test_httpd;

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
			'queue'		=> 'Returns information about the relayd queue. Takes no arguments.',
			'uname'		=> 'Returns the uname of the machine. Takes no arguments.',
			'time'		=> 'Returns the local time of the machine. Takes no arguments.',
			'df'		=> 'Returns the free space of the machine. Takes no arguments.',
			'relaying'	=> 'Returns the status of the relayd. Takes one optional argument: a bool value.',
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

	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Time: $time" );

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

	# TODO lousy hack here
	my $uname = `uname -a`;
	chomp( $uname );

	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Uname: $uname" );

	return;
}

sub irc_botcmd_queue : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	# TODO ugly code here
	$_[HEAP]->{'relayd'}->queue->_easydbi->arrayhash(
		sql => 'SELECT count(*) AS count from queue',
		event => '_got_queuecount',
		_where => $where,
	);

	return;
}

sub _got_queuecount : State {
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
	$_[HEAP]->{'IRC'}->yield( privmsg => $result->{'_where'}, "RELAYING $status - Number of entries in the queue: " . $result->{result}->[0]->{'count'} );

	return;
}

sub irc_botcmd_relaying : State {
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
