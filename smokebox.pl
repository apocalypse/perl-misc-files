#!/usr/bin/env perl
use strict; use warnings;

# This script should be used after you've compiled all the perls
# Please run compile_perl.pl first!

# TODO
#	- I saw this in a report: http://www.nntp.perl.org/group/perl.cpan.testers/2009/12/msg6450349.html
#		TMPDIR = /export/home/bob/cpantesting/tmp/
#	- remove all .cpanplus/build cruft if disk space is not enough
#		http://search.cpan.org/~iguthrie/Filesys-DfPortable-0.85/DfPortable.pm
#		cpan@ubuntu-server64:~$ rm -rf /home/cpan/.cpanplus/authors/id/*				# downloaded tarballs
#		cpan@ubuntu-server64:~$ rm -rf /home/cpan/cpanp_conf/perl-5.10.0-default/.cpanplus/build/*	# extracted builds
#	- we should just update the system CPANPLUS, and the symlinks will handle the rest of the perls...

use POE;
use POE::Component::SmokeBox 0.30;		# must be > 0.30 for the no_log param
use POE::Component::SmokeBox::Smoker;
use POE::Component::SmokeBox::Job;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::BotCommand;
use base 'POE::Session::AttributeBased';

use Data::Dumper;
use Sys::Hostname qw( hostname );
use Time::Duration qw( duration_exact );

# set some handy variables
my $ircnick = hostname();

POE::Session->create(
	__PACKAGE__->inline_states(),
);

POE::Kernel->run();
exit 0;

sub _start : State {
	$_[KERNEL]->alias_set( 'smoker' );

	# setup our stuff
	$_[KERNEL]->yield( 'create_smokebox' );
	$_[KERNEL]->yield( 'create_irc' );

	return;
}

sub create_smokebox : State {
	$_[HEAP]->{'SMOKEBOX'} = POE::Component::SmokeBox->spawn();

	# Add system perl...
	# Configuration successfully saved to CPANPLUS::Config::User
	#    (/home/apoc/.cpanplus/lib/CPANPLUS/Config/User.pm)
	my $perl = `which perl`; chomp $perl;
	my $smoker = POE::Component::SmokeBox::Smoker->new(
		perl => $perl,
		env => {
			'APPDATA'		=> "$ENV{HOME}/",
			'PERL5_YACSMOKE_BASE'	=> "$ENV{HOME}/",
		},
	);
	$_[HEAP]->{'SMOKEBOX'}->add_smoker( $smoker );
	$_[HEAP]->{'PERLS'} = {};

	# Store the system smoker so we can use it to update the CPANPLUS index
	$_[HEAP]->{'SMOKER_SYSTEM'} = $smoker;

	# Do the first pass over our perls
	$_[KERNEL]->yield( 'check_perls' );

	return;
}

sub check_perls : State {
	# get the available perl versions
	my $perls = getPerlVersions();

	# any new ones?
	my @newones;
	foreach my $p ( @$perls ) {
		if ( ! exists $_[HEAP]->{'PERLS'}->{ $p } ) {
			push( @newones, $p );
		}
	}

	# add them!
	foreach my $p ( @newones ) {
		$_[HEAP]->{'SMOKEBOX'}->add_smoker( POE::Component::SmokeBox::Smoker->new(
			perl => "$ENV{HOME}/perls/$p/bin/perl",
			env => {
				'APPDATA'		=> "$ENV{HOME}/cpanp_conf/$p/",
				'PERL5_YACSMOKE_BASE'	=> "$ENV{HOME}/cpanp_conf/$p/",
			},
		) );

		# save the smoker
		$_[HEAP]->{'PERLS'}->{ $p } = undef;
	}

	# Every hour we re-check the perls so we can add new ones
	$_[KERNEL]->delay_add( 'check_perls' => 60 * 60 );

	return;
}

sub create_irc : State {
	# create the IRC bot
	$_[HEAP]->{'IRC'} = POE::Component::IRC::State->spawn(
		nick	=> $ircnick,
		ircname	=> $ircnick,
		server	=> '192.168.0.200',
#		Flood	=> 1,
	) or die "Unable to spawn irc: $!";

	$_[HEAP]->{'IRC'}->plugin_add( 'AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => { '#smoke' => '' } ) );
	$_[HEAP]->{'IRC'}->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new() );
	$_[HEAP]->{'IRC'}->plugin_add( 'BotCommand', POE::Component::IRC::Plugin::BotCommand->new(
		Commands => {
			'queue'		=> 'Returns information about the smoker job queue. Takes no arguments.',
			'smoke'		=> 'Adds the specified module to the smoke queue. Takes one argument: the module name.',
			'index'		=> 'Updates the CPANPLUS source index. Takes no arguments.',
			'status'	=> 'Enables/disables the smoker. Takes one optional argument: a boolean.',
			'perls'		=> 'Lists the available perl versions to smoke. Takes no arguments.',
			'uname'		=> 'Returns the uname of the machine the smokebot is running on. Takes no arguments.',
		},
		Addressed => 0,
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
	$_[HEAP]->{'SMOKEBOX'}->shutdown();
	undef $_[HEAP]->{'SMOKEBOX'};
	$_[HEAP]->{'IRC'}->shutdown();
	undef $_[HEAP]->{'IRC'};

	return;
}

# gets the perls
sub getPerlVersions {
	my @perls;
	opendir( PERLS, "$ENV{HOME}/perls" ) or die "Unable to opendir: $!";

	# TODO for now, we just find the default perls
#	@perls = grep { /^perl\-/ && -d "$ENV{HOME}/perls/$_" && -e "$ENV{HOME}/perls/$_/ready.smoke" } readdir( PERLS );
	@perls = grep { /^perl\-[\d\.]+\-default/ && -d "$ENV{HOME}/perls/$_" && -e "$ENV{HOME}/perls/$_/ready.smoke" } readdir( PERLS );
	closedir( PERLS ) or die "Unable to closedir: $!";

	return \@perls;
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

	my $queue = [ $_[HEAP]->{'SMOKEBOX'}->queues ]->[0];
	my $numjobs = $queue->pending_jobs();
	my $currjob = $queue->current_job();
	if ( defined $currjob ) {
		$currjob = $currjob->{'job'};
		my $current = $currjob->command;
		if ( $current eq 'smoke' ) {
			$current .= " " . $currjob->module;
		}
		$currjob = $current;
	}

	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Number of jobs in the queue: ${numjobs}." . ( defined $currjob ? " Current job: $currjob" : '' ) );

	return;
}

sub irc_botcmd_status : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	my $queue = [ $_[HEAP]->{'SMOKEBOX'}->queues ]->[0];

	if ( defined $arg ) {
		if ( $arg ) {
			if ( ! $queue->queue_paused ) {
				$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Job queue was already running!" );
			} else {
				$queue->resume_queue();

				$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Resumed the job queue." );
			}
		} else {
			if ( $queue->queue_paused ) {
				$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Job queue was already paused!" );
			} else {
				$queue->pause_queue();

				$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Paused the job queue." );
			}
		}
	} else {
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Status of job queue: " . ( $queue->queue_paused() ? "PAUSED" : "RUNNING" ) );
	}

	return;
}

sub irc_botcmd_smoke : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	# Send off the job!
	$_[HEAP]->{'SMOKEBOX'}->submit( event => 'smokeresult',
		job => POE::Component::SmokeBox::Job->new(
			command => 'smoke',
			module => $arg,
			type => 'CPANPLUS::YACSmoke',
			no_log => 1,
		),
	);

	# hack: ignore the CPAN bot!
	if ( $nick ne 'CPAN' ) {
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Added $arg to the job queue." );
	}

	return;
}

sub smokeresult : State {
	# extract some useful data
	my $starttime = 0;
	my $endtime = 0;
	my $passes = 0;
	my $fails = 0;
	my $module;

	foreach my $r ( $_[ARG0]->{'result'}->results() ) {
		if ( $r->{'status'} == 0 ) {
			$passes++;
		} else {
			$fails++;
		}

		if ( $starttime == 0 or $r->{'start_time'} < $starttime ) {
			$starttime = $r->{'start_time'};
		}
		if ( $endtime == 0 or $r->{'end_time'} > $endtime ) {
			$endtime = $r->{'end_time'};
		}

		$module = $r->{'module'};
	}
	my $duration = duration_exact( $endtime - $starttime );

	# report this to IRC
	$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "Smoked $module ($passes PASS, $fails FAIL) in ${duration}." );

	return;
}

sub irc_botcmd_index : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	# Send off the job!
	$_[HEAP]->{'SMOKEBOX'}->submit( event => 'indexresult',
		job => POE::Component::SmokeBox::Job->new(
			command => 'index',
			type => 'CPANPLUS::YACSmoke',
			no_log => 1,
		),
	);

	# hack: ignore the CPAN bot!
	if ( $nick ne 'CPAN' ) {
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Added CPAN index to the job queue." );
	}

	return;
}

sub indexresult : State {
	# extract some useful data
	my $starttime = 0;
	my $endtime = 0;
	my $passes = 0;
	my $fails = 0;

	foreach my $r ( $_[ARG0]->{'result'}->results() ) {
		if ( $r->{'status'} == 0 ) {
			$passes++;
		} else {
			$fails++;
		}

		if ( $starttime == 0 or $r->{'start_time'} < $starttime ) {
			$starttime = $r->{'start_time'};
		}
		if ( $endtime == 0 or $r->{'end_time'} > $endtime ) {
			$endtime = $r->{'end_time'};
		}
	}
	my $duration = duration_exact( $endtime - $starttime );

	# report this to IRC
	$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "Updated the CPANPLUS index ($passes PASS, $fails FAIL) in ${duration}." );

	return;
}

sub irc_botcmd_perls : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	# get the available versions
	my $perls = keys %{ $_[HEAP]->{'PERLS'} };

	# don't forget to +1 for the SYSTEM perl!
	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Available Perls: " . ( $perls + 1 ) );

	return;
}

__END__
