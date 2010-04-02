#!/usr/bin/env perl
use strict; use warnings;

# This script should be used after you've compiled all the perls
# Please run compile_perl.pl first!

# TODO
#	- we should just update the system CPANPLUS, and the symlinks will handle the rest of the perls...

use POE;
use POE::Component::SmokeBox 0.36;		# must be > 0.32 for the delay stuff + 0.36 for loop bug fix
use POE::Component::SmokeBox::Smoker;
use POE::Component::SmokeBox::Job;
use POE::Component::IRC::State 6.18;		# 6.18 depends on POE::Filter::IRCD 2.42 to shutup warnings about 005 numerics
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::BotCommand;
use base 'POE::Session::AttributeBased';

use Sys::Hostname qw( hostname );
use Time::Duration qw( duration_exact );
use Filesys::DfPortable;
use File::Spec;
use File::Path::Tiny;
use Number::Bytes::Human qw( format_bytes );

# set some handy variables
my $ircnick = hostname();
my $ircserver = '192.168.0.200';
my $freespace = 1024 * 1024 * 1024 * 5;	# set it to 5GB - in bytes before we auto-purge CPAN files
my $delay = 60;				# set delay in seconds between jobs/smokers to "throttle"

# Set our system info
my %VMs = (
	# hostname => full text
	'ubuntu-server64'	=> 'Ubuntu 9.10 server 64bit (192.168.0.202)',
	'freebsd64'		=> 'FreeBSD 7.2-RELEASE amd64 (192.168.0.203)',
	'netbsd64'		=> 'NetBSD 5.0.1 amd64 (192.168.0.205)',
	'opensolaris64'		=> 'OpenSolaris 2009.06 amd64 (192.168.0.207)',
);

POE::Session->create(
	__PACKAGE__->inline_states(),
);

POE::Kernel->run();
exit 0;

sub _start : State {
	$_[KERNEL]->alias_set( 'smoker' );

	# Always enable SmokeBox debugging so we can dump output to a log
	$ENV{PERL5_SMOKEBOX_DEBUG} = 1;
	my $logfile = 'smokebox.log.' . time();
	open( my $logfh, '>', $logfile ) or die "Unable to open '$logfile': $!";
	$SIG{'__WARN__'} = sub {
		print STDOUT $_[0];
		print $logfh $_[0];
	};

	# setup our stuff
	$_[KERNEL]->yield( 'create_smokebox' );
	$_[KERNEL]->yield( 'create_irc' );

	return;
}

sub create_smokebox : State {
	$_[HEAP]->{'SMOKEBOX'} = POE::Component::SmokeBox->spawn(
# TODO disable delay so we smoke CT2.0 full blast for testing
#		'delay'	=> $delay,
	);

# TODO disable system perl because I want a controlled environment for now...
#	# Add system perl...
#	# Configuration successfully saved to CPANPLUS::Config::User
#	#    (/home/apoc/.cpanplus/lib/CPANPLUS/Config/User.pm)
#	my $perl = `which perl`; chomp $perl;
#	my $smoker = POE::Component::SmokeBox::Smoker->new(
#		perl => $perl,
#		env => {
#			'APPDATA'		=> $ENV{HOME},
#			'PERL5_YACSMOKE_BASE'	=> $ENV{HOME},
#			'TMPDIR'		=> File::Spec->catdir( $ENV{HOME}, 'tmp' ),
#			'PERL_CPANSMOKER_HOST'	=> $VMs{ $ircnick },
#		},
#	);
#	$_[HEAP]->{'SMOKEBOX'}->add_smoker( $smoker );
#
#	# Store the system smoker so we can use it to update the CPANPLUS index
#	$_[HEAP]->{'SMOKER_SYSTEM'} = $smoker;

	# Store the local perls we built
	$_[HEAP]->{'PERLS'} = {};

	# Do the first pass over our perls
	$_[KERNEL]->yield( 'check_perls' );

	# Do cleanup of cruft
	$_[KERNEL]->yield( 'check_free_space' );

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
			perl => File::Spec->catfile( $ENV{HOME}, 'perls', $p, 'bin', 'perl' ),
			env => {
				'APPDATA'		=> File::Spec->catdir( $ENV{HOME}, 'cpanp_conf', $p ),
				'PERL5_YACSMOKE_BASE'	=> File::Spec->catdir( $ENV{HOME}, 'cpanp_conf', $p ),
				'TMPDIR'		=> File::Spec->catdir( $ENV{HOME}, 'tmp' ),
				'PERL_CPANSMOKER_HOST'	=> $VMs{ $ircnick },
				'PERL5_CPANIDX_URL'	=> 'http://' . $ircserver . ':11110/CPANIDX/',	# TODO fix this hardcoded path
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
		server	=> $ircserver,
# TODO investigate why our local ircd kicks us off...
#		Flood	=> 1,
	) or die "Unable to spawn irc: $!";

	$_[HEAP]->{'IRC'}->plugin_add( 'AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => { '#smoke' => '' } ) );
	$_[HEAP]->{'IRC'}->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new() );
	$_[HEAP]->{'IRC'}->plugin_add( 'BotCommand', POE::Component::IRC::Plugin::BotCommand->new(
		Commands 	=> {
			'queue'		=> 'Returns information about the smoker job queue. Takes no arguments.',
			'smoke'		=> 'Adds the specified module to the smoke queue. Takes one argument: the module name.',
#			'index'		=> 'Updates the CPANPLUS source index. Takes no arguments.',
			'status'	=> 'Enables/disables the smoker. Takes one optional argument: a boolean.',
			'perls'		=> 'Lists the available perl versions to smoke. Takes no arguments.',
			'uname'		=> 'Returns the uname of the machine the smokebot is running on. Takes no arguments.',
			'time'		=> 'Returns the local time of the machine. Takes no arguments.',
			'df'		=> 'Returns the free space of the machine. Takes no arguments.',
			'delay'		=> 'Sets the delay for PoCo-SmokeBox. Takes one optional argument: number of seconds.',
		},
		Addressed 	=> 0,
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
	# TODO add real shutdown method to handle ctrl-c
	$_[HEAP]->{'SMOKEBOX'}->shutdown();
	undef $_[HEAP]->{'SMOKEBOX'};
	$_[HEAP]->{'IRC'}->shutdown();
	undef $_[HEAP]->{'IRC'};

	return;
}

# gets the perls
sub getPerlVersions {
	# TODO fix the path to be compatible with MSWin32

	# look for ready perls only
	opendir( PERLS, File::Spec->catdir( $ENV{HOME}, 'perls' ) ) or die "Unable to opendir: $!";
	my @perls = grep { /^perl\_[\d\.]+/ && -d File::Spec->catdir( $ENV{HOME}, 'perls', $_ ) && -e File::Spec->catfile( $ENV{HOME}, 'perls', $_, 'ready.smoke' ) } readdir( PERLS );
	closedir( PERLS ) or die "Unable to closedir: $!";

	return \@perls;
}

sub irc_botcmd_delay : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	if ( defined $arg ) {
		if ( $arg =~ /^\d+$/ ) {
			$delay = $arg;
			$_[HEAP]->{'SMOKEBOX'}->delay( $arg );
			$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Set delay to: $arg seconds." );
		} else {
			$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Delay($arg) is not a number!" );
		}
	} else {
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "The current delay is: $delay seconds." );
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

	my $queue = [ $_[HEAP]->{'SMOKEBOX'}->queues ]->[0];
	my $numjobs = $queue->pending_jobs();
	my $currjob = $queue->current_job();
	if ( defined $currjob ) {
		my $current = $currjob->{'job'}->command;
		if ( $current eq 'smoke' ) {
			$current .= " " . $currjob->{'job'}->module;
		}

		# get the starttime
		my $starttime = 0;
		if ( scalar @{ $currjob->{'result'} } ) {
			foreach my $r ( $currjob->{'result'}->results() ) {
				if ( $starttime == 0 or $r->{'start_time'} < $starttime ) {
					$starttime = $r->{'start_time'};
				}
			}
		} else {
			# take it from the current backend
			$starttime = $currjob->{'backend'}->{'start_time'};
		}

		# Add time info
		$current .= ", still working after " . duration_exact( time - $starttime );
		if ( defined $currjob->{'backend'} ) {
			$current .= ", running(" . $currjob->{'backend'}->{'perl'} . ")";
		}

		# Add smokers info
		# TODO fix wrong calculation bug...
		# <netbsd64> Number of jobs in the queue: 0. Current job: smoke Pod::Simple, still working after 7 minutes and 56 seconds, running(/home/cpan/perls/perl-5.8.2-default/bin/perl), with 15/19 perls done.
		# <netbsd64> Number of jobs in the queue: 0. Current job: smoke Pod::Simple, still working after 9 minutes and 50 seconds, running(/home/cpan/perls/perl-5.6.1-default/bin/perl), with 18/20 perls done.
		my $smokedone = scalar @{ $currjob->{'result'} };
		my $smokeleft = scalar @{ $currjob->{'smokers'} };
		if ( $smokeleft == 0 ) {
			$smokeleft = 1;
		}
		if ( defined $currjob->{'backend'} ) {
			$smokeleft++;
		}
		$current .= ", with " . $smokedone . "/" . ( $smokeleft + $smokedone ) . " perls done.";

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

	# Cleanse any whitespace ( damn irc clients! )
	$arg =~ s/\s+\z//;

	# Send off the job!
	$_[HEAP]->{'SMOKEBOX'}->submit( event => 'smokeresult',
		job => POE::Component::SmokeBox::Job->new(
			command => 'smoke',
			module => $arg,
			type => 'CPANPLUS::YACSmoke',
			no_log => 1,

# TODO smoke full blast for CT2.0 testing
#			delay => $delay,
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
	my $endtime = time;
	my @fails;
	my $module = $_[ARG0]->{'job'}->module;

	foreach my $r ( $_[ARG0]->{'result'}->results() ) {
		if ( $r->{'status'} != 0 ) {
			push( @fails, $r->{'perl'} );
		}

		if ( $starttime == 0 or $r->{'start_time'} < $starttime ) {
			$starttime = $r->{'start_time'};
		}
	}
	my $duration = duration_exact( $endtime - $starttime );

	# report this to IRC
	$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "Smoked $module " . ( scalar @fails ? '(FAIL: ' . join( ' ', @fails ) . ' ) ' : '' ) . "in ${duration}." );

	# TODO inspect the tmp dir for droppings and report it!
	# this would require proper callbacks in SmokeBox

	# We always do this after smoking
	$_[KERNEL]->yield( 'check_free_space' );

	return;
}

sub check_free_space : State {
	my $do_purge = $_[ARG0];

	# TODO this is a ugly hack, until we get proper callbacks from SmokeBox

#	<Apocalypse> I need some serious CPANPLUS smarts - in my CPAN smoker script I wipe the crud ( build dirs, downloaded tarballs, etc ) when free space is less than X, but I got my logic wrong
#	<Apocalypse> What I do is basically rm -rf those directories under the .cpanplus root: authors/*, $perlver/build/*
#	<Apocalypse> But what I managed to do was to totally hose the perl install and ended up sending gazillions of FAIL to cpantesters :(
#	<Apocalypse> How do I sanely clean up everything in the cpanplus dir?
#	<Apocalypse> Hmm, maybe I should just use CPANPLUS::YACSmoke's "flush" thingie
#	<kane> Apocalypse: after you whipe that, you need to rebuild the indexes i suppose
#	<@kane> 'x' from the default shell or the equivalent method in cpanplus::backend
#	<Apocalypse> kane: Ah that's the part I didn't do - I just wiped the dirs then proceeded to smoke the next dist
#	<Apocalypse> I didn't realize the indexes included info about built dists
#	<kane> Apocalypse: they don't, but you also threw away the parsed version of the index cpanplus uses internally
#	<@kane> depending on what you have and haven't loaded by then, Weird Stuff(tm) may happen
#	<Apocalypse> Makes sense :)
#	<Apocalypse> What happened to me was this - http://www.nntp.perl.org/group/perl.cpan.testers/2010/01/msg6675283.html
#	<+dipsy> [ FAIL File-BOM-0.14 i86pc-solaris 2.11 - nntp.perl.org ]
#	<Apocalypse> Lots of modules thought their deps were "installed" but I actually wiped them out...
#	<Apocalypse> I'll re-create this situation and see if rebuilding the indexes fixed it
#	<Apocalypse> Thanks again kane!

	my $df = dfportable( $ENV{HOME} );
	if ( defined $df ) {
		# Do we need to wipe?
		if ( $df->{'bavail'} < $freespace or $do_purge ) {
			# TODO need to implement proper callbacks in poco-smokebox so we can force an index if this happens
			$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "Apocalypse: Disk space getting low!" );
			exit;

			# cpan@ubuntu-server64:~$ rm -rf /home/cpan/.cpanplus/authors/*						# downloaded tarballs
			my $dir = File::Spec->catdir( $ENV{HOME}, '.cpanplus', 'authors' );
			if ( -d $dir ) {
				File::Path::Tiny::rm( $dir ) or die "Unable to rmdir ($dir): $!";
			}

			# cpan@ubuntu-server64:~$ rm -rf /home/cpan/.cpanplus/5.8.9/build/*					# extracted builds
			$dir = File::Spec->catdir( $ENV{HOME}, '.cpanplus' );
			opendir( DIR, $dir ) or die "Unable to opendir ($dir): $!";
			foreach my $d ( readdir( DIR ) ) {
				if ( $d =~ /^[\d\.]+$/ ) {
					$d = File::Spec->catdir( $dir, $d );
					if ( -d $d ) {
						File::Path::Tiny::rm( $d ) or die "Unable to rmdir ($d): $!";
					}
				}
			}
			closedir( DIR ) or die "Unable to closedir ($dir): $!";

			# cpan@ubuntu-server64:~$ rm -rf /home/cpan/cpanp_conf/perl-5.10.0-default/.cpanplus/5.10.0/build/*	# extracted builds
			$dir = File::Spec->catdir( $ENV{HOME}, 'cpanp_conf' );
			opendir( DIR, $dir ) or die "Unable to opendir ($dir): $!";
			foreach my $d ( readdir( DIR ) ) {
				if ( $d =~ /^perl\-([\d\.]+)\-/ ) {
					$d = File::Spec->catdir( $dir, $d, '.cpanplus', $1 );
					if ( -d $d ) {
						File::Path::Tiny::rm( $d ) or die "Unable to rmdir ($d): $!";
					}
				}
			}
			closedir( DIR ) or die "Unable to closedir ($dir): $!";

			# cpan@ubuntu-server64:~$ rm -rf /home/cpan/tmp/*							# temporary space for builds
			$dir = File::Spec->catdir( $ENV{HOME}, 'tmp' );
			File::Path::Tiny::rm( $dir ) or die "Unable to rmdir ($dir): $!";
			mkdir( $dir ) or die "Unable to mkdir ($dir): $!";
		}
	} else {
		warn "Unable to get DF from filesystem!";
	}

	return;
}

#sub irc_botcmd_index : State {
#	my $nick = (split '!', $_[ARG0])[0];
#	my ($where, $arg) = @_[ARG1, ARG2];
#
#	# Send off the job!
#	$_[HEAP]->{'SMOKEBOX'}->submit( event => 'indexresult',
#		job => POE::Component::SmokeBox::Job->new(
#			command => 'index',
#			type => 'CPANPLUS::YACSmoke',
#			no_log => 1,
#
## TODO smoke full blast for CT2.0 testing
##			delay => $delay,
#		),
#	);
#
#	# hack: ignore the CPAN bot!
#	if ( $nick ne 'CPAN' ) {
#		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Added CPAN index to the job queue." );
#	}
#
#	return;
#}

#sub indexresult : State {
#	# extract some useful data
#	my $starttime = 0;
#	my $endtime = time;
#	my @fails;
#
#	foreach my $r ( $_[ARG0]->{'result'}->results() ) {
#		if ( $r->{'status'} != 0 ) {
#			push( @fails, $r->{'perl'} );
#		}
#
#		if ( $starttime == 0 or $r->{'start_time'} < $starttime ) {
#			$starttime = $r->{'start_time'};
#		}
#	}
#	my $duration = duration_exact( $endtime - $starttime );
#
#	# report this to IRC
#	$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "Updated the CPANPLUS index " . ( scalar @fails ? '(FAIL: ' . join( ' ', @fails ) . ' ) ' : '' ) . "in ${duration}." );
#
#	# We always do this after indexing
#	$_[KERNEL]->yield( 'check_free_space' );
#
#	return;
#}

sub irc_botcmd_perls : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	# get the available versions
	my $perls = keys %{ $_[HEAP]->{'PERLS'} };

	# don't forget to +1 for the SYSTEM perl!
	# TODO disabled system perl for now
	#$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Available Perls: " . ( $perls + 1 ) );
	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Available Perls: $perls" );

	return;
}

__END__
