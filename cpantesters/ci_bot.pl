#!/usr/bin/env perl
use strict; use warnings;

# This script should be used after you've compiled all the perls
# Please run compile_perl.pl first!

# TODO list:
#
#	- look at smokebox.pl because a lot of the code in here is cribbed from there

use POE;
use POE::Component::SmokeBox 0.38;		# must be > 0.32 for the delay stuff + 0.36 for loop bug fix + 0.38 for the name
use POE::Component::SmokeBox::Smoker;
use POE::Component::SmokeBox::Job;
use POE::Component::IRC::State 6.18;		# 6.18 depends on POE::Filter::IRCD 2.42 to shutup warnings about 005 numerics
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::BotCommand;
use POE::Component::Client::HTTP;
use base 'POE::Session::AttributeBased';

use Sys::Hostname qw( hostname );
use Time::Duration qw( duration_exact );
use Filesys::DfPortable qw( dfportable );
use File::Spec;
use File::Path::Tiny;
use Shell::Command qw( mv );
use Number::Bytes::Human qw( format_bytes );
use Parse::CPAN::Meta;	# minimal YAML parser we need, thanks CPANIDX for the idea!
use HTTP::Request;

# set some handy variables
my $ircnick = hostname();
my $ircserver = 'cpan.0ne.us';
my $ircpass = 'apoc4cpan';
my $freespace = 1024 * 1024 * 1024 * 5;	# set it to 5GB - in bytes before we auto-purge CPAN files
my $delay = 0;				# set delay in seconds between jobs/smokers to "throttle"
my $use_system = 0;			# use the system perl binary too?
my $ci_enabled = 1;			# enable/disable CI smoking
my $ci_server = $ircserver;		# The CI server IP ( in my case it's the same as the IRC server, ha! )
my $ci_port = 11_112;			# The port on the ircserver for the CI httpd
my $HOME = $ENV{HOME};			# home path to search for perls/etc
if ( $^O eq 'MSWin32' ) {
	$HOME = "C:\\cpansmoke";
}

POE::Session->create(
	__PACKAGE__->inline_states(),
);

POE::Kernel->run();
exit 0;

sub _start : State {
	$_[KERNEL]->alias_set( 'smoker' );

	# TODO how to limit log size/rotation/etc?
#	# Always enable SmokeBox debugging so we can dump output to a log
#	$ENV{PERL5_SMOKEBOX_DEBUG} = 1;
#	my $logfile = 'smokebox.log';
#	open( my $logfh, '>', $logfile ) or die "Unable to open '$logfile': $!";
#	$SIG{'__WARN__'} = sub {
#		my $l = $_[0];
#		$l =~ s/(?:\r|\n)+$//;	# Needed so we get consistent newline output on MSWin32
#		print STDOUT $l, "\n";
#		print $logfh $l, "\n";
#	};

	$_[HEAP]->{'PERLS'} = {};

	# Make sure tmp dir is empty
	my $dir = File::Spec->catdir( $HOME, 'tmp' );
	if ( -d $dir ) {
		File::Path::Tiny::rm( $dir ) or die "Unable to rmdir ($dir): $!";
		mkdir( $dir ) or die "Unable to mkdir ($dir): $!";
	}

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
	if ( $use_system and $^O ne 'MSWin32' ) {
		# Configuration successfully saved to CPANPLUS::Config::User
		#    (/home/apoc/.cpanplus/lib/CPANPLUS/Config/User.pm)
		my $perl = $^X; chomp $perl;
		my $smoker = POE::Component::SmokeBox::Smoker->new(
			perl => $perl,
			env => {
				'APPDATA'		=> $HOME,
				'PERL5_YACSMOKE_BASE'	=> $HOME,
				'TMPDIR'		=> File::Spec->catdir( $HOME, 'tmp' ),
				'PERL_CPANSMOKER_HOST'	=> $perl . ' / ' . $ircnick,
				'PERL5_CPANIDX_URL'	=> 'http://' . $ircserver . ':11110/CPANIDX/',	# TODO fix this hardcoded path
			},
			do_callback => $_[SESSION]->callback( 'smokebox_callback', 'SYSTEM' ),
			name => 'SYSTEM',
		);
		$_[HEAP]->{'SMOKEBOX'}->add_smoker( $smoker );

		# Store the system perl
		$_[HEAP]->{'PERLS'}->{ $perl } = undef;
	}

	# Do the first pass over our perls
	$_[KERNEL]->yield( 'check_perls' );

	# Finally, ask the CI server to get our dists
	$_[KERNEL]->yield( 'ci_start' ) if $ci_enabled;

	return;
}

sub smokebox_callback : State {
	my( $myarg, $smokearg ) = @_[ARG0, ARG1];

	if ( $smokearg->[0] eq 'AFTER' ) {
		# We need to check disk space for sanity
		$_[KERNEL]->call( $_[SESSION], 'check_free_space' );
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
				'PERL_CPANSMOKER_HOST'	=> $p . ' / ' . $ircnick,
				'PERL5_CPANIDX_URL'	=> 'http://' . $ircserver . ':11110/CPANIDX/',	# TODO fix this hardcoded path
			},
			do_callback => $_[SESSION]->callback( 'smokebox_callback', $p ),
			name => $p,
		) );

		# save the smoker
		$_[HEAP]->{'PERLS'}->{ $p } = 1;
	}

	# Every 12 hours we re-check the perls so we can add new ones
	$_[KERNEL]->delay_add( 'check_perls' => 60 * 60 * 12 );

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
		Password => $ircpass,
		Flood	=> 1,
	) or die "Unable to spawn irc: $!";

	$_[HEAP]->{'IRC'}->plugin_add( 'AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => { '#smoke' => '' } ) );
	$_[HEAP]->{'IRC'}->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new() );
	$_[HEAP]->{'IRC'}->plugin_add( 'BotCommand', POE::Component::IRC::Plugin::BotCommand->new(
		Commands 	=> {
			'status'	=> 'Returns information about the smoker job queue. Takes no arguments.',
			'smoking'	=> 'Get/Set the status of the smoker. Takes one optional argument: a bool value.',
			'perls'		=> 'Lists the available perl versions to smoke. Takes no arguments.',
			'uname'		=> 'Returns the uname of the machine. Takes no arguments.',
			'time'		=> 'Returns the local time of the machine. Takes no arguments.',
			'df'		=> 'Returns the free space of the machine. Takes no arguments.',
			'delay'		=> 'Get/Set the delay for PoCo-SmokeBox. Takes one optional argument: number of seconds.',
			'ci'		=> 'Get/Set the status of the CI bot. Takes one optional qrgument: a bool value.',
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
	$_[KERNEL]->call( 'ua' => 'shutdown' ) if exists $_[HEAP]->{'HTTP'};

	return;
}

# gets the perls
sub getPerlVersions {
	# look for ready perls only
	opendir( my $p, File::Spec->catdir( $HOME, 'perls' ) ) or die "Unable to opendir: $!";
	my @perls = grep { /perl\_[\d\.\w\-]+\_/ && -d File::Spec->catdir( $HOME, 'perls', $_ ) && -e File::Spec->catfile( $HOME, 'perls', $_, 'ready.smoke' ) } readdir( $p );
	closedir( $p ) or die "Unable to closedir: $!";

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
	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Time: $time (" . localtime($time) . ")" );

	return;
}

sub irc_botcmd_df : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	my $df = dfportable( $HOME );
	if ( defined $df ) {
		my $free = format_bytes( $df->{'bavail'}, 'si' => 1 );
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
		my $smokedone = scalar @{ $currjob->{'result'} };
		my $smokeleft = scalar @{ $currjob->{'smokers'} };
		if ( defined $currjob->{'backend'} ) {
			$smokeleft++;
		}
		$current .= ", with " . $smokedone . "/" . ( $smokeleft + $smokedone ) . " perls done.";

		$currjob = $current;
	}

	my $ci_status = $ci_enabled ? 'ENABLED' : 'DISABLED';
	my $smoke_status = $queue->queue_paused ? 'DISABLED' : 'ENABLED';
	my $block_status = exists $_[HEAP]->{'BLOCK'} ? ' Smoking block( ' . uc( $_[HEAP]->{'BLOCK'} ) . ' )' : '';
	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "CI ${ci_status}$block_status, Smoking $smoke_status => Number of jobs in the queue: ${numjobs}." . ( defined $currjob ? " Current job: $currjob" : '' ) );

	return;
}

sub irc_botcmd_smoking : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	my $queue = [ $_[HEAP]->{'SMOKEBOX'}->queues ]->[0];

	if ( defined $arg ) {
		if ( $arg =~ /^(?:0|1)$/ ) {
			if ( $arg ) {
				if ( ! $queue->queue_paused ) {
					$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Smoker was already enabled!" );
				} else {
					$queue->resume_queue;

					$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Enabling the smoker..." );
				}
			} else {
				if ( $queue->queue_paused ) {
					$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Smoker was already disabled!" );
				} else {
					$queue->pause_queue;

					$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Disabling the smoker..." );
				}
			}
		} else {
			$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Invalid argument - it must be 0 or 1' );
		}
	} else {
		my $status = $queue->queue_paused ? 'DISABLED' : 'ENABLED';
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Smoker status: $status" );
	}

	return;
}

sub irc_botcmd_ci : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	if ( defined $arg ) {
		if ( $arg =~ /^(?:0|1)$/ ) {
			if ( $arg ) {
				if ( $ci_enabled ) {
					$_[HEAP]->{'IRC'}->yield( privmsg => $where, "CI was already enabled!" );
				} else {
					$ci_enabled = 1;
					$_[KERNEL]->yield( 'ci_start' );

					$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Enabling the CI..." );
				}
			} else {
				if ( ! $ci_enabled ) {
					$_[HEAP]->{'IRC'}->yield( privmsg => $where, "CI was already disabled!" );
				} else {
					$ci_enabled = 0;

					$_[HEAP]->{'IRC'}->yield( privmsg => $where, "Disabling the CI..." );
				}
			}
		} else {
			$_[HEAP]->{'IRC'}->yield( privmsg => $where, 'Invalid argument - it must be 0 or 1' );
		}
	} else {
		my $status = $ci_enabled ? 'ENABLED' : 'DISABLED';
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "CI status: $status" );
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
			push( @fails, $r );
		}

		if ( $starttime == 0 or $r->{'start_time'} < $starttime ) {
			$starttime = $r->{'start_time'};
		}
	}
	my $duration = duration_exact( $endtime - $starttime );

	# report this to IRC
	foreach my $r ( @fails ) {
		my $fail = 'UNKNOWN';
		foreach my $failtype ( qw( idle excess term ) ) {
			if ( exists $r->{ $failtype . '_kill' } ) {
				$fail = $failtype;
				last;
			}
		}

		$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "FAIL $module on $r->{'perl'} reason: $fail kill" );
	}

#	$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "Smoked $module in ${duration}." );

	# Have we finished our assignment?
	my $queue_count = scalar ( [ $_[HEAP]->{'SMOKEBOX'}->queues ]->[0]->pending_jobs );
	if ( $queue_count == 0 ) {
		# Yay, tell the CI server we are done with this block!
		$_[KERNEL]->yield( 'ci_done' );
	}

	return;
}

sub ci_done : State {
	# Get the duration
	my $duration = time - $_[HEAP]->{'BLOCK_TS'};

	# Okay, tell the CI server we are done with this block
	$_[KERNEL]->post(
		'ua' => 'request',
		'ci_done_reply',
		HTTP::Request->new( GET => "http://$ci_server:$ci_port/CI/done/$ircnick/" . $_[HEAP]->{'BLOCK'} . "/$duration" ),
		{ duration => $duration },
	);

	return;
}

sub ci_done_reply : State {
	my ($request_packet, $response_packet) = @_[ARG0, ARG1];

#	warn "Got response from CI for DONE:\n" . $response_packet->[0]->as_string;

	if ( $response_packet->[0]->is_error ) {
		# TODO change to an exponential backoff delay?
		die "CI server isn't responding: " . $response_packet->[0]->as_string;
	}

	my $res;
	eval { $res = Parse::CPAN::Meta::Load( $response_packet->[0]->content ); };
	if ( $@ or ! defined $res ) {
		die "Unable to load response from CI server: $@";
	}

	# Did we get a-OK?
	if ( $res->{'result'} ) {
		# let IRC know
		my $duration = duration_exact( $response_packet->[1]->{'duration'} );
		$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "Finished smoking block( " . uc( $_[HEAP]->{'BLOCK'} ) . " ) in $duration" );

		# Then, start all over
		if ( $ci_enabled ) {
			$_[KERNEL]->yield( 'ci_start' );
		} else {
			delete $_[HEAP]->{'BLOCK'};
			delete $_[HEAP]->{'BLOCK_TS'};
		}
	} else {
		die "Got bad answer from CI server for DONE";
	}

	return;
}

sub ci_start : State {
	# Do we have a http client spawned?
	if ( ! exists $_[HEAP]->{'HTTP'} ) {
		POE::Component::Client::HTTP->spawn(
			Alias => 'ua',
		);
		$_[HEAP]->{'HTTP'} = 1;
	}

	# Okay, tell the CI server to give us a new block to process
	$_[KERNEL]->post(
		'ua' => 'request',
		'ci_start_reply',
		HTTP::Request->new( GET => "http://$ci_server:$ci_port/CI/start/$ircnick" ),
	);

	return;
}

sub ci_start_reply : State {
	my ($request_packet, $response_packet) = @_[ARG0, ARG1];

#	warn "Got response from CI for START:\n" . $response_packet->[0]->as_string;

	if ( $response_packet->[0]->is_error ) {
		die "CI server isn't responding: " . $response_packet->[0]->as_string;
	}

	my $res;
	eval { $res = Parse::CPAN::Meta::Load( $response_packet->[0]->content ); };
	if ( $@ or ! defined $res ) {
		die "Unable to load response from CI server: $@";
	}

	# Do we have to purge?
	if ( exists $res->{'purge'} and $res->{'purge'} ) {
		# TODO clear the free space
		# AND <-- is important!
		# clear the cpansmoke db file!@!!!!
		die "We need to purge the cpansmoke db - WE FINISHED SMOKING CPAN :)";
	}

	# Okay, we now have a block and a list of dists to smoke :)
	$_[HEAP]->{'BLOCK'} = $res->{'block'};
	$_[HEAP]->{'BLOCK_TS'} = time;
	foreach my $d ( @{ $res->{'dists'} } ) {
		$_[HEAP]->{'SMOKEBOX'}->submit( event => 'smokeresult',
			job => POE::Component::SmokeBox::Job->new(
				command => 'smoke',
				module => $d,
				type => 'CPANPLUS::YACSmoke',
				delay => $delay,

				# Don't store the output anywhere, it may get huge!
				no_log => 1,

				# disable use of String::Perl::Warnings which sometimes blows up perl - rt.perl.org #74484
				check_warnings => 0,
			),
		);
	}

	$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "Started smoking block( " . uc( $res->{'block'} ) . " ) with " . scalar @{ $res->{'dists'} } . " dists" );

	# If we got no dists to smoke, proceed to the next block!
	if ( ! scalar @{ $res->{'dists'} } ) {
		$_[KERNEL]->yield( 'ci_done' );
	}

	return;
}

sub check_free_space : State {
	# Since sometimes it takes forever to wipe, we need to do it asynchronously!
	my @wipe_dirs;
	my @wipe_files;

	# TODO this should never happen... I think it can be safely removed
	return if exists $_[HEAP]->{'ASYNC_DEL'};

	my $df = dfportable( $HOME );
	if ( defined $df ) {
		# Do we need to wipe?
		if ( $df->{'bavail'} < $freespace ) {
			# inform the irc netizens :)
			$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "WARNING: Disk space getting low, executing purge!" );

			# Cleanup the system perl if needed
			my $dir = File::Spec->catdir( $HOME, '.cpanplus' );
			if ( -d $dir ) {
				opendir( my $cpanp, $dir ) or die "Unable to opendir ($dir): $!";
				foreach my $d ( readdir( $cpanp ) ) {
					# downloaded tarballs
					# cpan@ubuntu-server64:~$ rm -rf /home/cpan/.cpanplus/authors/*
					if ( $d eq 'authors' ) {
						$d = File::Spec->catdir( $dir, $d );
						if ( -d $d ) {
							push( @wipe_dirs, $d );
						}

					# extracted builds
					# cpan@ubuntu-server64:~$ rm -rf /home/cpan/.cpanplus/5.8.9/*
					} elsif ( $d =~ /^[\d\.]+$/ ) {
						$d = File::Spec->catdir( $dir, $d );
						if ( -d $d ) {
							push( @wipe_dirs, $d );
						}

					# Since we are using CPANIDX, we can make sure any index files disappear :)
					} elsif ( $d =~ /^(01mailrc|02packages|03modlist|sourcefiles)/ ) {
						$d = File::Spec->catfile( $dir, $d );
						if ( -f $d ) {
							push( @wipe_files, $d );
						}
					}
				}
				closedir( $cpanp ) or die "Unable to closedir ($dir): $!";
			}

			# wipe out each perl version
			$dir = File::Spec->catdir( $HOME, 'cpanp_conf' );
			opendir( my $cpanp, $dir ) or die "Unable to opendir ($dir): $!";
			foreach my $d ( readdir( $cpanp ) ) {
				if ( $d =~ /perl\_([\d\.\w\-]+)\_/ ) {
					$d = File::Spec->catdir( $dir, $d, '.cpanplus' );
					my $build = File::Spec->catdir( $d, $1 );
					my $authors = File::Spec->catdir( $d, 'authors' );

					# downloaded tarballs
					# cpan@ubuntu-server64:~$ rm -rf /home/cpan/cpanp_conf/perl-5.10.0-default/.cpanplus/authors/*
					if ( -d $authors ) {
						push( @wipe_dirs, $authors );
					}

					# extracted tarballs
					# cpan@ubuntu-server64:~$ rm -rf /home/cpan/cpanp_conf/perl-5.10.0-default/.cpanplus/5.10.0/*
					if ( -d $build ) {
						push( @wipe_dirs, $build );
					}

					# Since we are using CPANIDX, we can make sure any index files disappear :)
					opendir( my $p, $d ) or die "Unable to opendir ($d): $!";
					foreach my $idx ( readdir( $p ) ) {
						if ( $idx =~ /^(01mailrc|02packages|03modlist|sourcefiles)/ ) {
							my $file = File::Spec->catfile( $d, $idx );
							if ( -f $file ) {
								push( @wipe_files, $file );
							}
						}
					}
					closedir( $p ) or die "Unable to closedir ($d): $!";
				}
			}
			closedir( $cpanp ) or die "Unable to closedir ($dir): $!";
		}
	} else {
		warn "Unable to get DF from filesystem!";
	}

	# async delete need us to do some magic!
	if ( @wipe_dirs or @wipe_files ) {
		# tell smokebox to pause itself
		[ $_[HEAP]->{'SMOKEBOX'}->queues ]->[0]->pause_queue_now;

		$_[KERNEL]->yield( 'async_del' => { 'dirs' => \@wipe_dirs, 'files' => \@wipe_files, 'cb' => 'wipe_done' } );
	}

	return;
}

sub wipe_done : State {
	# tell smokebox to resume
	[ $_[HEAP]->{'SMOKEBOX'}->queues ]->[0]->resume_queue;

	return;
}

# TODO this should be factored out into a PoCo! ( PoCo::AsyncFileManager or something )
# Also, this should be "invisible" to the end-user!
# see POE::Quickie, LWP::UserAgent::POE for examples
# the ideal thing would be to export async_unlink, async_rmdir, async_rmtree functions
sub async_del : State {
	my $arg = $_[ARG0];

	# Silently convert dirs to our format
	$arg->{'dirs'} = [ map { [ 0, $_ ] } @{ $arg->{'dirs'} } ] if exists $arg->{'dirs'};

	if ( exists $_[HEAP]->{'ASYNC_DEL'} ) {
		push( @{ $_[HEAP]->{'ASYNC_DEL'} }, $arg );
	} else {
		$_[HEAP]->{'ASYNC_DEL'} = [ $arg ];

		# okay, go ahead and delete!
		$_[KERNEL]->yield( 'async_del_do' );
	}

	return;
}

sub async_del_do : State {
	my $req = $_[HEAP]->{'ASYNC_DEL'}->[0];

	# We process the files first
	if ( scalar @{ $req->{'files'} } ) {
		my $f = shift @{ $req->{'files'} };
		unlink( $f ) or die "Unable to unlink($f): $!";
		$_[KERNEL]->yield( 'async_del_do' );
		return;
	}

	# Okay, we clean up the dirs next
	# Code partially inspired from File::Path::Tiny
	if ( scalar @{ $req->{'dirs'} } ) {
		# process the first directory in it
		my $dir = $req->{'dirs'}->[0];

		# have we processed this dir yet?
		if ( $dir->[0] ) {
			rmdir( $dir->[1] ) or die "Unable to rmdir($dir->[1]): $!";
			shift @{ $req->{'dirs'} };
			if ( scalar @{ $req->{dirs} } ) {
				$_[KERNEL]->yield( 'async_del_do' );
				return;
			}
		} else {
			opendir( my $p, $dir->[1] ) or die "Unable to opendir($dir->[1]): $!";
			while ( my $f = readdir( $p ) ) {
				next if $f eq '.' or $f eq '..';
				$f = File::Spec->catfile( $dir->[1], $f );
				if ( -d $f and ! -l $f ) {
					unshift( @{ $req->{'dirs'} }, [ 0, $f ] );
				} else {
					unshift( @{ $req->{'files'} }, $f );
				}
			}
			closedir( $p ) or die "Unable to closedir($dir->[1]): $!";
			$dir->[0] = 1; # we are done processing this dir

			$_[KERNEL]->yield( 'async_del_do' );
			return;
		}
	}

	# Wow, we finally finished a request!
	$_[KERNEL]->yield( $req->{'cb'} );
	shift @{ $_[HEAP]->{'ASYNC_DEL'} };
	if ( scalar @{ $_[HEAP]->{'ASYNC_DEL'} } ) {
		$_[KERNEL]->yield( 'async_del_do' );
	} else {
		delete $_[HEAP]->{'ASYNC_DEL'};
	}

	return;
}

# TODO need to move this logic into CPANPLUS itself so I can pinpoint which dependency caused it...
#sub check_tmp_dir : State {
#	my( $myarg, $smokearg ) = @_[ARG0, ARG1];
#	my $perlver = $myarg->[0];
#	my $module = $smokearg->[2]->{module};
#	my $dir = File::Spec->catdir( $HOME, 'tmp' );
#
#	if ( -d $dir ) {
#		# check the dir for droppings - thanks BinGOs for the idea!
#		opendir( TMPDIR, $dir ) or die "Unable to opendir($dir): $!";
#		my @files = readdir( TMPDIR );
#		closedir( TMPDIR ) or die "Unable to closedir($dir): $!";
#		if ( scalar @files > 2 ) {
#			$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "DROPPINGS detected in tmpdir, courtesy of $module on $perlver" );
#		}
#
#		# temporary space for builds
#		# cpan@ubuntu-server64:~$ rm -rf /home/cpan/tmp/*
#		File::Path::Tiny::rm( $dir ) or die "Unable to rmdir ($dir): $!";
#		mkdir( $dir ) or die "Unable to mkdir ($dir): $!";
#	}
#
#	return;
#}

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
