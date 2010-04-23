#!/usr/bin/env perl
use strict; use warnings;

# This script should be used after you've compiled all the perls
# Please run compile_perl.pl first!

# TODO list:
#
#	- enable irc control of which perls to smoke ( i.e. !perls 5.12.0 # will enable only 5.12.0 perl, bla bla )
#	- use symlinks for windows? ( to avoid costly mv's ) http://shell-shocked.org/article.php?id=284

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
use Filesys::DfPortable qw( dfportable );
use File::Spec;
use File::Path::Tiny;
use Shell::Command qw( mv );
use Number::Bytes::Human qw( format_bytes );

# set some handy variables
my $ircnick = hostname();
my $ircserver = '192.168.0.200';
my $freespace = 1024 * 1024 * 1024 * 5;	# set it to 5GB - in bytes before we auto-purge CPAN files
my $delay = 0;				# set delay in seconds between jobs/smokers to "throttle"
my $HOME = $ENV{HOME};			# home path to search for perls/etc
if ( $^O eq 'MSWin32' ) {
	$HOME = "C:\\cpansmoke";
}

# Set our system info
my %VMs = (
	# hostname => full text
	'ubuntu-server64'	=> 'Ubuntu 9.10 server 64bit (192.168.0.202)',
	'freebsd64.0ne.us'	=> 'FreeBSD 7.2-RELEASE amd64 (192.168.0.203)',
	'netbsd64'		=> 'NetBSD 5.0.1 amd64 (192.168.0.205)',
	'opensolaris64'		=> 'OpenSolaris 2009.6 amd64 (192.168.0.207)',
	'satellite'		=> 'Windows XP 32bit',	# TODO blah, get a real VM! :)
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
		my $l = $_[0];
		$l =~ s/(?:\r|\n)+$//;	# Needed so we get consistent newline output on MSWin32
		print STDOUT $l, "\n";
		print $logfh $l, "\n";
	};

	$_[HEAP]->{'PERLS'} = {};

	# setup our stuff
	$_[KERNEL]->yield( 'create_smokebox' );
	$_[KERNEL]->yield( 'create_irc' );

	return;
}

sub create_smokebox : State {
	$_[HEAP]->{'SMOKEBOX'} = POE::Component::SmokeBox->spawn(
		'delay'	=> $delay,
	);

	# Add system perl...
	# TODO, we can actually smoke bootperl, eh?
	if ( $^O ne 'MSWin32' ) {
		# Configuration successfully saved to CPANPLUS::Config::User
		#    (/home/apoc/.cpanplus/lib/CPANPLUS/Config/User.pm)
		my $perl = $^X; chomp $perl;
		my $smoker = POE::Component::SmokeBox::Smoker->new(
			perl => $perl,
			env => {
				'APPDATA'		=> $HOME,
				'PERL5_YACSMOKE_BASE'	=> $HOME,
				'TMPDIR'		=> File::Spec->catdir( $HOME, 'tmp' ),
				'PERL_CPANSMOKER_HOST'	=> $perl . ' / ' . $VMs{ $ircnick },
				'PERL5_CPANIDX_URL'	=> 'http://' . $ircserver . ':11110/CPANIDX/',	# TODO fix this hardcoded path
			},
			do_callback => $_[SESSION]->callback( 'smokebox_callback', 'SYSTEM' ),
		);
		$_[HEAP]->{'SMOKEBOX'}->add_smoker( $smoker );

		# Store the system perl
		$_[HEAP]->{'PERLS'}->{ $perl } = undef;
	}

	# Do the first pass over our perls
	$_[KERNEL]->yield( 'check_perls' );

	# Do cleanup of cruft
	$_[KERNEL]->yield( 'check_free_space' );

	return;
}

sub smokebox_callback : State {
	my( $myarg, $smokearg ) = @_[ARG0, ARG1];

	# Check tmp dir for droppings - thanks to BinGOs for the idea!
	if ( $smokearg->[0] eq 'AFTER' ) {
		# TODO do this!
		#check_tmp_directory( $_[HEAP], $myarg, $smokearg );
	}

	# Do special actions for win32
	if ( $^O eq 'MSWin32' ) {
		# We need to move the custom perls to strawberry dir and back to the home dir
		if ( $myarg->[0] ne 'SYSTEM' ) {
			my $path = File::Spec->catdir( $HOME, 'perls', $myarg->[0] );
			my $straw = File::Spec->catdir( 'C:', 'strawberry' );

			if ( $smokearg->[0] eq 'BEFORE' ) {
				# Move the perl to C:\strawberry!

				# Sanity checks
				if ( -d $straw ) {
					die "Old Strawberry Perl found in '$straw' - please fix it!";
				}
				if ( ! -d $path ) {
					die "Strawberry Perl not found in '$path' - please fix it!";
				}

				mv( $path, $straw ) or die "Unable to mv: $!";

				# TODO wtf? Shell::Command::mv didn't return FAIL on win32 and it actually failed to move
				# the directory one time...
				if ( ! -d $straw ) {
					die "Unable to mv - system is problematic!";
				}
			} else {
				# move the perl back to C:\$home\perls\$dist

				# Sanity checks
				if ( ! -d $straw ) {
					die "Strawberry Perl not found in '$straw' - please fix it!";
				}
				if ( -d $path ) {
					die "Old Strawberry Perl found in '$path' - please fix it!";
				}

				mv( $straw, $path ) or die "Unable to mv: $!";

				# Same problem as above...
				if ( ! -d $path ) {
					die "Unable to mv - system is problematic!";
				}
			}
		}
	}

	# Always return 1 so BEGIN callback is happy :)
	return 1;
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
			# perl binary is different for strawberry perl!
			( $^O eq 'MSWin32' ? ( perl => File::Spec->catfile( 'C:', 'strawberry', 'perl', 'bin', 'perl.exe' ) ) :
				( perl => File::Spec->catfile( $HOME, 'perls', $p, 'bin', 'perl' ) ) ),

			env => {
				# Goddamnit C:\bootperl\c\bin is in the PATH so it ends up executing dmake.EXE from there not Strawberry!
				# TODO this doesn't work all the time... weird!
				( $^O eq 'MSWin32' ? ( 'PATH' => cleanse_strawberry_path() ) : () ),

				'APPDATA'		=> File::Spec->catdir( $HOME, 'cpanp_conf', $p ),
				'PERL5_YACSMOKE_BASE'	=> File::Spec->catdir( $HOME, 'cpanp_conf', $p ),
				'TMPDIR'		=> File::Spec->catdir( $HOME, 'tmp' ),
				'PERL_CPANSMOKER_HOST'	=> $p . ' / ' . $VMs{ $ircnick },
				'PERL5_CPANIDX_URL'	=> 'http://' . $ircserver . ':11110/CPANIDX/',	# TODO fix this hardcoded path
			},
			do_callback => $_[SESSION]->callback( 'smokebox_callback', $p ),
		) );

		# save the smoker
		$_[HEAP]->{'PERLS'}->{ $p } = 1;
	}

	# Every hour we re-check the perls so we can add new ones
	$_[KERNEL]->delay_add( 'check_perls' => 60 * 60 );

	return;
}

sub cleanse_strawberry_path {
	my @path = split( ';', $ENV{PATH} );
	my @newpath;
	foreach my $p ( @path ) {
		if ( $p !~ /bootperl/ and $p !~ /strawberry/ ) {
			push( @newpath, $p );
		}
	}
	push( @newpath, File::Spec->catdir( 'C:', 'strawberry', 'c', 'bin' ) );
	push( @newpath, File::Spec->catdir( 'C:', 'strawberry', 'perl', 'bin' ) );
	return join( ';', @newpath );
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
			'status'	=> 'Enables/disables the smoker. Takes one optional argument: a boolean.',
			'perls'		=> 'Lists the available perl versions to smoke. Takes no arguments.',
			'uname'		=> 'Returns the uname of the machine. Takes no arguments.',
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
	# look for ready perls only
	opendir( PERLS, File::Spec->catdir( $HOME, 'perls' ) ) or die "Unable to opendir: $!";
	my @perls = grep { /perl\_[\d\.\w\-]+\_/ && -d File::Spec->catdir( $HOME, 'perls', $_ ) && -e File::Spec->catfile( $HOME, 'perls', $_, 'ready.smoke' ) } readdir( PERLS );
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

	my $df = dfportable( $HOME );
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
			delay => $delay,

			# disable use of String::Perl::Warnings which sometimes blows up rt.perl.org #74484
			check_warnings => 0,
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
	$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "Smoked $module " . ( scalar @fails ? '(FAIL: ' . join( ' ', @fails ) . ') ' : '' ) . "in ${duration}." );

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

	# TODO Hmm, now that I'm using CPANIDX do we need to do anything "special" for it?

	my $df = dfportable( $HOME );
	if ( defined $df ) {
		# Do we need to wipe?
		if ( $df->{'bavail'} < $freespace or $do_purge ) {
			# TODO need to implement proper callbacks in poco-smokebox so we can force an index if this happens
			$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "Apocalypse: Disk space getting low!" );
			exit;

			# cpan@ubuntu-server64:~$ rm -rf /home/cpan/.cpanplus/authors/*						# downloaded tarballs
			my $dir = File::Spec->catdir( $HOME, '.cpanplus', 'authors' );
			if ( -d $dir ) {
				File::Path::Tiny::rm( $dir ) or die "Unable to rmdir ($dir): $!";
			}

			# cpan@ubuntu-server64:~$ rm -rf /home/cpan/.cpanplus/5.8.9/build/*					# extracted builds
			$dir = File::Spec->catdir( $HOME, '.cpanplus' );
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
			$dir = File::Spec->catdir( $HOME, 'cpanp_conf' );
			opendir( DIR, $dir ) or die "Unable to opendir ($dir): $!";
			foreach my $d ( readdir( DIR ) ) {
				if ( $d =~ /perl\_([\d\.\w\-]+)\_/ ) {
					$d = File::Spec->catdir( $dir, $d, '.cpanplus', $1 );
					if ( -d $d ) {
						File::Path::Tiny::rm( $d ) or die "Unable to rmdir ($d): $!";
					}
				}
			}
			closedir( DIR ) or die "Unable to closedir ($dir): $!";

			# cpan@ubuntu-server64:~$ rm -rf /home/cpan/tmp/*							# temporary space for builds
			$dir = File::Spec->catdir( $HOME, 'tmp' );
			File::Path::Tiny::rm( $dir ) or die "Unable to rmdir ($dir): $!";
			mkdir( $dir ) or die "Unable to mkdir ($dir): $!";
		}
	} else {
		warn "Unable to get DF from filesystem!";
	}

	return;
}

sub irc_botcmd_perls : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	# get the available versions
#	my $msg = "Available Perls(" . ( scalar keys %{ $_[HEAP]->{'PERLS'} } ) . "): " . join( ' ', keys %{ $_[HEAP]->{'PERLS'} } );

	# Don't show all perls because... it overflows the IRCd length limit hah
	my $msg = "Available Perls: " . ( scalar keys %{ $_[HEAP]->{'PERLS'} } );
	$_[HEAP]->{'IRC'}->yield( privmsg => $where, $msg );

	return;
}

__END__
