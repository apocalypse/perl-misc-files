#!/usr/bin/perl
use strict; use warnings;

# This script is the main "rsync" script that controls the smokers
# Every hour it runs the rsync
#	- after the rsync is done, it updates the local CPANIDX db
#	- each new dist is echoed to the irc channel, telling the smokers to go smoke it
# Also, you can tell it to smoke custom dists, using the !search option

# TODO list
#
#	- add the CPAN::WWW::Top100::Retrieve stuff ( need a POE wrapper for it, ha! )

use POE;
use POE::Component::SmokeBox::Uploads::Rsync;
use POE::Component::SmokeBox::Dists;
use POE::Component::IRC::State 6.18;			# 6.18 depends on POE::Filter::IRCD 2.42 to shutup warnings about 005 numerics
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::BotCommand;
use POE::Wheel::Run;
use base 'POE::Session::AttributeBased';

use Time::Duration qw( duration_exact );
use Number::Bytes::Human qw( format_bytes );
use Filesys::DfPortable;

# Set some handy variables
my $ircnick = 'CPAN';
my $ircserver = '192.168.0.200';
my $rsyncserver = 'cpan.dagolden.com::CPAN';	# Our favorite fast mirror
my $interval = 60 * 60;				# rsync every hour
my $do_rsync = 1;				# enable rsyncing

POE::Session->create(
	__PACKAGE__->inline_states(),
);

POE::Kernel->run;
exit 0;

sub _start : State {
	$_[KERNEL]->alias_set( 'CPAN' );

	# setup our stuff
	$_[KERNEL]->yield( 'create_rsync' ) if $do_rsync;
	$_[KERNEL]->yield( 'create_irc' );

	return;
}

sub create_rsync : State {
	# Tell the poco to start it's stuff!
	POE::Component::SmokeBox::Uploads::Rsync->spawn(
		'rsync_src'	=> $rsyncserver,
		'rsyncdone'	=> 'rsyncdone',
		'interval'	=> $interval,
		'alias'		=> 'rsyncd',
	) or die "Unable to spawn the poco-rsync!";

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
			'queue'		=> 'Returns information about the rsync queue. Takes no arguments.',
			'uname'		=> 'Returns the uname of the machine. Takes no arguments.',
			'time'		=> 'Returns the local time of the machine. Takes no arguments.',
			'df'		=> 'Returns the free space of the machine. Takes no arguments.',
			'search'	=> 'Searches for dists matching a criteria and uses them for smoking. Takes 2 arguments: type + regex.',
			'rsync'		=> 'Returns the rsync status. Takes one optional argument: a bool value.',
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
	$_[KERNEL]->post( 'SmokeBox-Rsync', 'shutdown' );
	return;
}

sub rsyncdone : State {
	my $r = $_[ARG0];

	if ( $r->{'status'} ) {
		$_[HEAP]->{'IRC'}->yield( privmsg => '#smoke', "Rsync run done in " . duration_exact( $r->{'stoptime'} - $r->{'starttime'} ) . " with $r->{'dists'} new dists!" );
		if ( $r->{'dists'} > 0 ) {
			# start an index run!
#			$_[HEAP]->{'IRC'}->yield( privmsg => '#smoke', "!index" );

			$_[KERNEL]->yield( 'run_cpanidx' );
		}
	} else {
		$_[HEAP]->{'IRC'}->yield( privmsg => '#smoke', "Rsync run failed in " . duration_exact( $r->{'stoptime'} - $r->{'starttime'} ) . " with error: $r->{'exit'}!" );
	}

	# take note of the time
	$_[HEAP]->{'RSYNCTS'} = time;

	return;
}

sub run_cpanidx : State {
	# Kill the old one, if it's still around
	if ( defined $_[HEAP]->{'CPANIDX'} ) {
		$_[HEAP]->{'CPANIDX'}->kill( -9 );
		undef $_[HEAP]->{'CPANIDX'};
	}

	my $wheel = POE::Wheel::Run->new(
		Program		=> [ 'cpanidx-gendb', ],
		StdoutEvent	=> 'pwr_stdout',
		StderrEvent	=> 'pwr_stderr',
		CloseEvent	=> 'pwr_close',
	);

	$_[KERNEL]->sig_child( $wheel->PID, 'pwr_child' );
	$_[HEAP]->{'CPANIDX'} = $wheel;

	return;
}

sub pwr_stdout : State {
	my( $line ) = $_[ARG0];

#warn "Got PWR:STDOUT: $line";

	return;
}

sub pwr_stderr : State {
	my( $line ) = $_[ARG0];

#warn "Got PWR:STDERR: $line";

	return;
}

sub pwr_close : State {
	my $id = $_[ARG0];

#warn "Got PWR:CLOSE";

	undef $_[HEAP]->{'CPANIDX'} if defined $_[HEAP]->{'CPANIDX'};

	return;
}

sub pwr_child : State {
	my $pid = $_[ARG1];

#warn "Got PWR:CHILD";

	undef $_[HEAP]->{'CPANIDX'} if defined $_[HEAP]->{'CPANIDX'};

	return;
}

sub upload : State {
	my $dist = $_[ARG0];

	$_[HEAP]->{'IRC'}->yield( privmsg => '#smoke', "!smoke $dist" );
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

	if ( $do_rsync ) {
		# Calculate the time left
		my $nowts = time;
		my $rsyncts = defined $_[HEAP]->{'RSYNCTS'} ? $_[HEAP]->{'RSYNCTS'} + 3600 : 0;
		my $duration;
		if ( $rsyncts == 0 ) {
			$duration = 'FIRST TIME';
		} elsif ( $rsyncts < $nowts ) {
			$duration = 'RUNNING';
		} else {
			$duration = duration_exact( $rsyncts - $nowts );
		}

		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Duration until the next rsync run: $duration" );
	} else {
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Rsyncd is disabled" );
	}

	return;
}

sub irc_botcmd_search : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	# We get 2 arguments: type and regex
	my( $type, $regex ) = split( ' ', $arg, 2 );
	$type = lc( $type );

	# TODO add "deps" type that will list $dist's requires/recommends prereqs for easier smoking
	# TODO also... "rdeps" ? that would rock! :)
	if ( $type !~ /^(?:author|distro|phalanx)$/ ) {
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Invalid type, allowed searches are: author distro phalanx' );
	} else {
		# Do we need a regex?
		if ( $type ne 'phalanx' ) {
			if ( ! defined $regex or ! length $regex ) {
				$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Please supply a regex for the search' );
			} else {
				# Is the regex valid?
				eval { my $r = qr/$regex/ };
				if ( $@ ) {
					$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Please supply a valid regex for the search' );
				} else {
					# Send it off!
					POE::Component::SmokeBox::Dists->$type(
						'search'	=> $regex,
						'event'		=> 'search_results',
						'url'		=> "ftp://$ircserver/CPAN/",
#						'pkg_time'	=> $interval,	# TODO wait for updated version of smokebox::dists
						'_where'	=> $where,
						'_arg'		=> $arg,
					);
				}
			}
		} else {
			# Send it off!
			POE::Component::SmokeBox::Dists->phalanx(
				'event'		=> 'search_results',
				'url'		=> "ftp://$ircserver/CPAN/",
#				'pkg_time'	=> $interval,	# TODO wait for updated version of smokebox::dists
				'_where'	=> $where,
				'_arg'		=> $arg,
			);
		}
	}

	return;
}

sub search_results : State {
	my $r = $_[ARG0];

	# Was there an error?
	if ( exists $r->{error} ) {
		$_[HEAP]->{'IRC'}->yield( privmsg => $r->{_where}, 'Error searching for(' . $r->{_arg} . '): ' . $r->{error} );
	} else {
		$_[HEAP]->{'IRC'}->yield( privmsg => $r->{_where}, 'Results for(' . $r->{_arg} . '): ' . scalar @{ $r->{dists} } . ' dists' );
		foreach my $dist ( @{ $r->{dists} } ) {
			$_[HEAP]->{'IRC'}->yield( privmsg => $r->{_where}, "!smoke $dist" );
		}
	}

	return;
}

sub irc_botcmd_rsync : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	if ( defined $arg ) {
		if ( $arg =~ /^(?:0|1)$/ ) {
			if ( $arg ) {
				if ( $do_rsync ) {
					$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Rsyncd was already enabled!' );
				} else {
					$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Enabling the rsyncd...' );
					$_[KERNEL]->yield( 'create_rsync' );
					$do_rsync = 1;
				}
			} else {
				if ( $do_rsync ) {
					$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Disabling the rsyncd...' );
					$_[KERNEL]->post( 'rsyncd', 'shutdown' );
					$do_rsync = 0;
				} else {
					$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Rsyncd was already disabled!' );
				}
			}
		} else {
			$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Invalid argument - it must be 0 or 1' );
		}
	} else {
		my $status = $do_rsync ? 'ENABLED' : 'DISABLED';
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Rsyncd status: $status" );
	}

	return;
}
