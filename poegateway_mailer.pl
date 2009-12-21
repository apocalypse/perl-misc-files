#!/usr/bin/perl
use strict; use warnings;

#sub Test::Reporter::POEGateway::Mailer::DEBUG () { 1 }

use POE;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::BotCommand;
use base 'POE::Session::AttributeBased';

use Test::Reporter::POEGateway::Mailer 0.03;	# needed for the delay stuff
use String::IRC;
use Number::Bytes::Human qw( format_bytes );
use Filesys::DfPortable;

# set some handy variables
my $ircnick = 'poegateway_mailer';
my $ircserver = '192.168.0.200';

POE::Session->create(
	__PACKAGE__->inline_states(),
);

POE::Kernel->run();
exit 0;

sub _start : State {
	$_[KERNEL]->alias_set( 'mailer' );

	# setup our stuff
	$_[KERNEL]->yield( 'create_mailer' );
	$_[KERNEL]->yield( 'create_irc' );

	return;
}

sub create_mailer : State {
	# let it do the work!
	Test::Reporter::POEGateway::Mailer->spawn(
		'host_aliases'  => {
			'192.168.0.201' => 'Ubuntu 9.10 server 32bit',
			'192.168.0.202' => 'Ubuntu 9.10 server 64bit',
			'192.168.0.203' => 'FreeBSD 7.2-RELEASE amd64',
			'192.168.0.204' => 'FreeBSD 7.2-RELEASE i386',
			'192.168.0.205' => 'NetBSD 5.0.1 amd64',
			'192.168.0.206' => 'NetBSD 5.0.1 x86',
			'192.168.0.207' => 'OpenSolaris 2009.06 amd64',
			'192.168.0.208' => 'OpenSolaris 2009.06 x86',
			'192.168.0.209' => 'Windows XP x86',
		},

		'delay'			=> 60,
		'maildone'		=> 'maildone',
		'mailer'		=> 'SMTP',
		'mailer_conf'		=> {
			'smtp_host'	=> 'wc3.0ne.us',
			'smtp_opts'	=> {
				'Port'	=> '465',
				'Hello'	=> '0ne.us',
			},
			'ssl'		=> 1,
			'auth_user'	=> 'XXXXXXXXXXX',
			'auth_pass'	=> 'XXXXXXXXXXX',
		},
	);

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

	$_[HEAP]->{'IRC'}->plugin_add( 'AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => { '#smoke' => '', '#cpantesters' => '', } ) );
	$_[HEAP]->{'IRC'}->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new() );
	$_[HEAP]->{'IRC'}->plugin_add( 'BotCommand', POE::Component::IRC::Plugin::BotCommand->new(
		Commands	=> {
			'queue'		=> 'Returns information about the email queue. Takes no arguments.',
			'uname'		=> 'Returns the uname of the machine the emailer is running on. Takes no arguments.',
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

sub _child : State {
	return;
}

sub _stop : State {
	$_[HEAP]->{'IRC'}->shutdown();
	undef $_[HEAP]->{'IRC'};

	return;
}

sub maildone : State {
	my $data = $_[ARG0];

	# extract the perl version for easier reporting
	# Perl: $^X = /home/cpan/perls/perl-5.8.3-default/bin/perl
	# TODO need to add windows support, ha!
	if ( $data->{'DATA'}->{'report'} =~ /^\s+Perl\:\s+\$\^X\s+\=\s+[\/\w\-\\]+(\d+\.\d+\.\d+)\-[\/\w\-\\]+$/m ) {
		$data->{'DATA'}->{'subject'} .= " perl-" . $1;
	}

	my $fromstr = "$data->{'DATA'}->{'_sender'}";
	if ( exists $data->{'DATA'}->{'_host'} ) {
		$fromstr = $data->{'DATA'}->{'_host'} . " - " . $fromstr;
	}

	if ( $data->{'DATA'}->{'subject'} =~ /^PASS/ ) {
		$data->{'DATA'}->{'subject'} = String::IRC->new( $data->{'DATA'}->{'subject'} )->green->stringify;
	} elsif ( $data->{'DATA'}->{'subject'} =~ /^FAIL/ ) {
		$data->{'DATA'}->{'subject'} = String::IRC->new( $data->{'DATA'}->{'subject'} )->red->stringify;
	}

	if ( $data->{'STATUS'} ) {
		$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#cpantesters', "Sent report( $data->{'DATA'}->{'subject'} ) From( $fromstr ) ID( $data->{'MSGID'} )" );
	} else {
		$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "Failed to send report( $data->{'DATA'}->{'subject'} ) From( $fromstr ) Error( $data->{'ERROR'} )" );
	}

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

	my $queue = $_[KERNEL]->call( 'POEGateway-Mailer', 'queue' );

	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Number of emails in the queue: $queue" );

	return;
}
