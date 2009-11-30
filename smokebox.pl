#!/usr/bin/perl
use strict; use warnings;

use Time::Duration qw( duration_exact );
use POE;
use POE::Component::SmokeBox;
use POE::Component::SmokeBox::Smoker;
use POE::Component::SmokeBox::Job;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::BotCommand;
use base 'POE::Session::AttributeBased';

use Data::Dumper;

# set some handy variables
my $ircnick = 'ubuntu-server-64';

# autoflush
$|++;

POE::Session->create(
	__PACKAGE__->inline_states(),
);

$poe_kernel->run();
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
	$_[HEAP]->{'SMOKEBOX'}->add_smoker( POE::Component::SmokeBox::Smoker->new(
		perl => $perl,
		env => {
			'APPDATA'		=> "$ENV{HOME}/",
			'PERL5_YACSMOKE_BASE'	=> "$ENV{HOME}/",
		},
	) );
	$_[HEAP]->{'PERLS'} = [];

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
		Flood	=> 1,
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
	return;
}

# gets the perls
sub getPerlVersions {
	my @perls;
	opendir( PERLS, "$ENV{HOME}/perls" ) or die "Unable to opendir: $@";
	@perls = grep { /^perl\-/ && -d "$ENV{HOME}/perls/$_" && -e "$ENV{HOME}/perls/$_/ready.smoke" } readdir( PERLS );
	closedir( PERLS ) or die "Unable to closedir: $@";

	return \@perls;
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

	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "${nick}: Number of jobs in the queue: ${numjobs}." . ( defined $currjob ? " Current job: $currjob" : '' ) );

	return;
}

sub irc_botcmd_status : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	my $queue = [ $_[HEAP]->{'SMOKEBOX'}->queues ]->[0];

	if ( defined $arg ) {
		if ( $arg ) {
			if ( ! $queue->queue_paused ) {
				$_[HEAP]->{'IRC'}->yield( privmsg => $where, "${nick}: Job queue was already running!" );
			} else {
				$queue->resume_queue();

				$_[HEAP]->{'IRC'}->yield( privmsg => $where, "${nick}: Resumed the job queue." );
			}
		} else {
			if ( $queue->queue_paused ) {
				$_[HEAP]->{'IRC'}->yield( privmsg => $where, "${nick}: Job queue was already paused!" );
			} else {
				$queue->pause_queue();

				$_[HEAP]->{'IRC'}->yield( privmsg => $where, "${nick}: Paused the job queue." );
			}
		}
	} else {
		$_[HEAP]->{'IRC'}->yield( privmsg => $where, "${nick}: Status of job queue: " . ( $queue->queue_paused() ? "PAUSED" : "RUNNING" ) );
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
		),
	);

	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "${nick}: Added $arg to the job queue." );

	return;
}

sub smokeresult : State {
	print Dumper( $_[ARG0] );

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
		if ( $endtime == 0 or $r->{'end_time'} < $endtime ) {
			$endtime = $r->{'end_time'};
		}

		$module = $r->{'module'};
	}
	my $duration = duration_exact( $endtime, $starttime );

	# report this to IRC
	$_[HEAP]->{'IRC'}->yield( 'privmsg' => '#smoke', "Smoked $module ($passes PASS, $fails FAIL) in ${duration}." );

	# TODO remove all .cpanplus/build cruft if disk space is not enough
	#cpan@ubuntu-server64:~$ rm -rf .cpanplus/authors/id/*
	#cpan@ubuntu-server64:~$ rm -rf .cpanplus/5.10.0/build/*

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
		),
	);

	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "${nick}: Added index to the job queue." );

	return;
}

sub indexresult : State {
	print Dumper( $_[ARG0] );

	# extract some useful data
	my $starttime = 0;
	my $endtime = 0;
	foreach my $r ( @{ $_[ARG0]->{'result'}->results() } ) {

		if ( $starttime == 0 or $r->{'start_time'} < $starttime ) {
			$starttime = $r->{'start_time'};
		}
		if ( $endtime == 0 or $r->{'end_time'} < $endtime ) {
			$endtime = $r->{'end_time'};
		}
	}
	my $duration = duration_exact( $endtime, $starttime );

	$_[HEAP]->{'IRC'}->yield( privmsg => "#smoke", "Finished updating CPANPLUS source index in ${duration}." );

	return;
}

sub irc_botcmd_perls : State {
	my $nick = (split '!', $_[ARG0])[0];
	my ($where, $arg) = @_[ARG1, ARG2];

	# get the available versions
	my $perls = keys %{ $_[HEAP]->{'PERLS'} };

	# don't forget to +1 for the SYSTEM perl!
	$_[HEAP]->{'IRC'}->yield( privmsg => $where, "${nick}: Available Perls(" . ( $perls + 1 ) . ")" );

	return;
}

__END__

cpan@ubuntu-server64:~$ ./smokebox.pl
$VAR1 = {
          'submitted' => 1259537221,
          'result' => bless( [
                               {
                                 'PID' => 9322,
                                 'env' => {
                                            'APPDATA' => '/home/cpan/cpanp_conf/perl-5.10.1-default/'
                                          },
                                 'status' => '0',
                                 'start_time' => 1259537221,
                                 'perl' => '/home/cpan/perls/perl-5.10.1-default/bin/perl',
                                 'end_time' => 1259537230,
                                 'log' => [
                                            '[MSG] Trying to get \'ftp://192.168.0.200/CPAN/authors/id/C/CW/CWEST/Acme-Drunk-0.03.tar.gz\'',
                                            '[MSG] Trying to get \'ftp://192.168.0.200/CPAN/authors/id/C/CW/CWEST/CHECKSUMS\'',
                                            '[MSG] Checksum matches for \'Acme-Drunk-0.03.tar.gz\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/Changes\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/lib/\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/lib/Acme/\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/lib/Acme/Drunk.pm\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/Makefile.PL\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/MANIFEST\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/MANIFEST.SKIP\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/META.yml\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/README\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/t/\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/t/01_test.t\'',
                                            '[MSG] Extracted \'Acme::Drunk\' to \'/home/cpan/cpanp_conf/perl-5.10.1-default/.cpanplus/5.10.1/build/Acme-Drunk-0.03\'',
                                            '[MSG] CPANPLUS is prefering Build.PL',
                                            '[MSG] Loading YACSmoke database "/home/cpan/cpanp_conf/perl-5.10.1-default/.cpanplus/cpansmoke.dat"',
                                            'Running [/home/cpan/perls/perl-5.10.1-default/bin/perl /home/cpan/perls/perl-5.10.1-default/bin/cpanp-run-perl /home/cpan/cpanp_conf/perl-5.10.1-default/.cpanplus/5.10.1/build/Acme-Drunk-0.03/Makefile.PL]...',
                                            'Checking if your kit is complete...',
                                            'Looks good',
                                            'Writing Makefile for Acme::Drunk',
                                            '[MSG] Checking for previous PASS result for "Acme-Drunk-0.03"',
                                            '[MSG] Module \'Acme::Drunk\' depends on \'Test::More\', may need to build a \'CPANPLUS::Dist::YACSmoke\' package for it as well',
                                            'Running [/usr/bin/make]...',
                                            'cp lib/Acme/Drunk.pm blib/lib/Acme/Drunk.pm',
                                            'Manifying blib/man3/Acme::Drunk.3',
                                            'Running [/usr/bin/make test]...',
                                            'PERL_DL_NONLAZY=1 /home/cpan/perls/perl-5.10.1-default/bin/perl "-MExtUtils::Command::MM" "-e" "test_harness(0, \'blib/lib\', \'blib/arch\')" t/*.t',
                                            't/01_test.t .. ok',
                                            'All tests successful.',
                                            'Files=1, Tests=2,  0 wallclock secs ( 0.00 usr  0.01 sys +  0.02 cusr  0.01 csys =  0.04 CPU)',
                                            'Result: PASS',
                                            '[MSG] MAKE TEST passed: PERL_DL_NONLAZY=1 /home/cpan/perls/perl-5.10.1-default/bin/perl "-MExtUtils::Command::MM" "-e" "test_harness(0, \'blib/lib\', \'blib/arch\')" t/*.t',
                                            't/01_test.t .. ok',
                                            'All tests successful.',
                                            'Files=1, Tests=2,  0 wallclock secs ( 0.00 usr  0.01 sys +  0.02 cusr  0.01 csys =  0.04 CPU)',
                                            'Result: PASS',
                                            '',
                                            '[MSG] Sending test report for \'Acme-Drunk-0.03\'',
                                            '[ERROR] CPANPLUS::Internals::Source::SQLite has not implemented writing state to disk',
                                            '',
                                            'CHLD 9322 0'
                                          ],
                                 'type' => 'CPANPLUS::YACSmoke',
                                 'module' => 'Acme::Drunk',
                                 'command' => 'smoke'
                               },
                               {
                                 'PID' => 9757,
                                 'env' => {
                                            'APPDATA' => '/home/cpan/',
                                            'SMOKEHOST' => 'ubuntu-server 64'
                                          },
                                 'status' => '0',
                                 'start_time' => 1259537230,
                                 'perl' => '/usr/bin/perl',
                                 'end_time' => 1259537308,
                                 'log' => [
                                            '[MSG] Rebuilding author tree, this might take a while',
                                            '[MSG] Rebuilding module tree, this might take a while',
                                            '[MSG] Trying to get \'ftp://192.168.0.200/CPAN/authors/id/C/CW/CWEST/Acme-Drunk-0.03.tar.gz\'',
                                            '[MSG] Trying to get \'ftp://192.168.0.200/CPAN/authors/id/C/CW/CWEST/CHECKSUMS\'',
                                            '[MSG] Checksum matches for \'Acme-Drunk-0.03.tar.gz\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/Changes\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/lib/\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/lib/Acme/\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/lib/Acme/Drunk.pm\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/Makefile.PL\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/MANIFEST\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/MANIFEST.SKIP\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/META.yml\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/README\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/t/\'',
                                            '[MSG] Extracted \'Acme-Drunk-0.03/t/01_test.t\'',
                                            '[MSG] Extracted \'Acme::Drunk\' to \'/home/cpan/.cpanplus/5.10.0/build/Acme-Drunk-0.03\'',
                                            '[MSG] CPANPLUS is prefering Build.PL',
                                            '[MSG] Loading YACSmoke database "/home/cpan/.cpanplus/cpansmoke.dat"',
                                            'Running [/usr/bin/perl /usr/local/bin/cpanp-run-perl /home/cpan/.cpanplus/5.10.0/build/Acme-Drunk-0.03/Makefile.PL]...',
                                            'Checking if your kit is complete...',
                                            'Looks good',
                                            'Writing Makefile for Acme::Drunk',
                                            '[MSG] Checking for previous PASS result for "Acme-Drunk-0.03"',
                                            '[MSG] Module \'Acme::Drunk\' depends on \'Test::More\', may need to build a \'CPANPLUS::Dist::YACSmoke\' package for it as well',
                                            'Running [/usr/bin/make]...',
                                            'cp lib/Acme/Drunk.pm blib/lib/Acme/Drunk.pm',
                                            'Manifying blib/man3/Acme::Drunk.3pm',
                                            'Running [/usr/bin/make test]...',
                                            'PERL_DL_NONLAZY=1 /usr/bin/perl "-MExtUtils::Command::MM" "-e" "test_harness(0, \'blib/lib\', \'blib/arch\')" t/*.t',
                                            't/01_test.t .. ok',
                                            'All tests successful.',
                                            'Files=1, Tests=2,  0 wallclock secs ( 0.00 usr  0.01 sys +  0.00 cusr  0.01 csys =  0.02 CPU)',
                                            'Result: PASS',
                                            '[MSG] MAKE TEST passed: PERL_DL_NONLAZY=1 /usr/bin/perl "-MExtUtils::Command::MM" "-e" "test_harness(0, \'blib/lib\', \'blib/arch\')" t/*.t',
                                            't/01_test.t .. ok',
                                            'All tests successful.',
                                            'Files=1, Tests=2,  0 wallclock secs ( 0.00 usr  0.01 sys +  0.00 cusr  0.01 csys =  0.02 CPU)',
                                            'Result: PASS',
                                            '',
                                            '[MSG] Sending test report for \'Acme-Drunk-0.03\'',
                                            '[MSG] Successfully sent \'pass\' report for \'Acme-Drunk-0.03\'',
                                            '[ERROR] CPANPLUS::Internals::Source::SQLite has not implemented writing state to disk',
                                            '',
                                            'CHLD 9757 0'
                                          ],
                                 'type' => 'CPANPLUS::YACSmoke',
                                 'module' => 'Acme::Drunk',
                                 'command' => 'smoke'
                               }
                             ], 'POE::Component::SmokeBox::Result' ),
          'job' => bless( {
                            'timeout' => [
                                           3600,
                                           qr/(?-xism:^\d+$)/
                                         ],
                            'type' => [
                                        'CPANPLUS::YACSmoke',
                                        sub { "DUMMY" }
                                      ],
                            'id' => [
                                      undef,
                                      sub { "DUMMY" }
                                    ],
                            'idle' => [
                                        600,
                                        qr/(?-xism:^\d+$)/
                                      ],
                            'command' => [
                                           'smoke',
                                           [
                                             'check',
                                             'index',
                                             'smoke'
                                           ]
                                         ],
                            'module' => [
                                          'Acme::Drunk',
                                          sub { "DUMMY" }
                                        ]
                          }, 'POE::Component::SmokeBox::Job' )
        };
cpan@ubuntu-server64:~$
