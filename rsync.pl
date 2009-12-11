#!/usr/bin/perl
use strict; use warnings;

use POE;
use POE::Component::SmokeBox::Uploads::Rsync;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use base 'POE::Session::AttributeBased';

use Time::Duration qw( duration_exact );

POE::Session->create(
	__PACKAGE__->inline_states(),
);

sub _start : State {
	$_[KERNEL]->alias_set( 'CPAN' );

	# setup our stuff
	$_[KERNEL]->yield( 'create_rsync' );
	$_[KERNEL]->yield( 'create_irc' );

	return;
}

sub create_rsync : State {
	# Tell the poco to start it's stuff!
	POE::Component::SmokeBox::Uploads::Rsync->spawn(
		'rsync_src'	=> 'cpan.dagolden.com::CPAN',
		'rsyncdone'	=> 'rsyncdone',
	) or die "Unable to spawn the poco-rsync!";

	return;
}

sub create_irc : State {
	# create the IRC bot
	$_[HEAP]->{'IRC'} = POE::Component::IRC::State->spawn(
		nick	=> 'CPAN',
		ircname	=> 'CPAN',
		server	=> '192.168.0.200',
		Flood	=> 1,
	) or die "Unable to spawn irc: $!";

	$_[HEAP]->{'IRC'}->plugin_add( 'AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => { '#smoke' => '' } ) );
	$_[HEAP]->{'IRC'}->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new() );

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
	$_[KERNEL]->post( 'SmokeBox-Rsync', 'shutdown' );
	return;
}

sub rsyncdone : State {
	my $r = $_[ARG0];

	if ( $r->{'status'} ) {
		$_[HEAP]->{'IRC'}->yield( privmsg => '#smoke', "Rsync run done in " . duration_exact( $r->{'stoptime'} - $r->{'starttime'} ) . " with $r->{'dists'} new dists!" );
		if ( $r->{'dists'} > 0 ) {
			# start an index run!
			$_[HEAP]->{'IRC'}->yield( privmsg => '#smoke', "!index" );
		}
	} else {
		$_[HEAP]->{'IRC'}->yield( privmsg => '#smoke', "Rsync run failed in " . duration_exact( $r->{'stoptime'} - $r->{'starttime'} ) . " with error: $r->{'exit'}!" );
	}

	return;
}

sub upload : State {
	$_[HEAP]->{'IRC'}->yield( privmsg => '#smoke', "!smoke $_[ARG0]" );
	return;
}

POE::Kernel->run;
