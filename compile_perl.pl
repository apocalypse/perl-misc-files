#!/usr/bin/env perl
use strict; use warnings;

# We have successfully compiled those perl versions:
# 5.6.1, 5.6.2
# 5.8.1, 5.8.2, 5.8.3, 5.8.4, 5.8.5, 5.8.6, 5.8.7, 5.8.8, 5.8.9
# 5.10.0 5.10.1
# 5.11.2

# This compiler builds each perl with a matrix of 49 possible combinations.
# Compiling the entire perl suite as of 5.11.2 will result in: 686 perls!
# Each perl averages 45M with all the necessary modules to smoke CPAN preinstalled. ( 30.15GB total! )

# this script does everything, but we need some layout to be specified!
# /home/cpan					<-- the main directory
# /home/cpan/CPANPLUS-0.XX			<-- the extracted CPANPLUS directory we use
# /home/cpan/build				<-- where we store our perl builds + tarballs
# /home/cpan/build/perl-5.6.2.tar.gz		<-- one perl tarball
# /home/cpan/build/perl-5.6.2-thr-32		<-- one extracted perl build
# /home/cpan/perls				<-- the perl installation directory
# /home/cpan/perls/perl-5.6.2-thr-32		<-- finalized perl install
# /home/cpan/cpanp_conf				<-- where we store the CPANPLUS configs
# /home/cpan/cpanp_conf/perl-5.6.2-thr-32	<-- CPANPLUS config location for a specific perl
# /home/cpan/compile_perl.pl			<-- where this script should be

# TODO LIST
#	- create "hints" file that sets operating system, 64bit, etc
#		- that way, we can know what perl versions to skip and etc
#		- maybe we can autodetect it?
#	- auto-config the root/system CPANPLUS?
#	- for the patch_hints thing, auto-detect the latest perl tarball and copy it from there instead of hardcoding it here...
#	- figure out how to install CPAN without somehow breaking CPANPLUS...

# load our dependencies
use Capture::Tiny qw( capture_merged tee_merged );
use Prompt::Timeout;
use Sort::Versions;
#use Term::Title qw( set_titlebar );	# TODO use this? too fancy...

# static var...
my $PATH = $ENV{HOME};	# the home path where we do our stuff
my $perlver;		# the perl version we're processing now
my $perlopts;		# the perl options we're using for this run
my $CPANPLUS_ver;	# the CPANPLUS version we'll use for cpanp-boxed
my $DEBUG = 0;		# spews stuff on console or just top-level data
my @LOGS = ();		# holds stored logs for a run
my $domatrix = 1;	# compile the matrix of perl options or not?
my @perls = ();		# the available perl tarballs found under $PATH/build

# ask user for debugging
prompt_debug();

# What option do we want to do?
prompt_action();

# all done!
exit;

sub prompt_action {
	my $res;
	while ( ! defined $res ) {
		$res = lc( prompt( "What action do you want to do today? [b/x/i/e/s]", 'b', 10, 1 ) );
		if ( $res eq 'b' ) {
			# Should we compile the matrix of options?
			prompt_perlmatrix();

			# prompt user for perl version to compile
			$res = prompt_perlver();
			if ( $res ne 'a' ) {
				# do the stuff!
				install_perl( $res );
			} else {
				# loop through all versions, starting from newest to oldest
				foreach my $p ( reverse @perls ) {
					install_perl( $p );
				}
			}
		} elsif ( $res eq 'x' ) {
			# update all CPANPLUS indexes
			do_log( "[CPANPLUS] Updating indexes on all perls..." );
			foreach my $p ( @{ getReadyperls() } ) {
				if ( do_cpanp_action( $p, "x --update_source" ) ) {
					do_log( "[CPANPLUS] Updated index on $p" );
				} else {
					do_log( "[CPANPLUS] Failed to update index on $p" );
				}
			}
		} elsif ( $res eq 'i' ) {
			# install a specific module
		} elsif ( $res eq 's' ) {
			# perform CPANPLUS s selfupdate all
			do_log( "[CPANPLUS] Executing selfupdate on all CPANPLUS installs..." );
			foreach my $p ( @{ getReadyperls() } ) {
				if ( do_cpanp_action( $p, "s selfupdate all" ) ) {
					do_log( "[CPANPLUS] Successfully updated CPANPLUS" );
				} else {
					do_log( "[CPANPLUS] Failed to update CPANPLUS" );
				}
			}
		} elsif ( $res eq 'e' ) {
			exit;
		} else {
			print "Unknown action, please try again.\n";
			$res = undef;
		}
	}

	return;
}

# finds all installed perls that have smoke.ready file in them
sub getReadyperls {
	opendir( PERLS, "$PATH/perls" ) or die "Unable to opendir: $!";
	my @list = readdir( PERLS );
	closedir( PERLS ) or die "Unable to closedir: $!";

	# find the ready ones
	my @ready = ();
	foreach my $p ( @list ) {
		if ( $p =~ /^perl\-/ and -d "$PATH/perls/$p" and -e "$PATH/perls/$p/ready.smoke" ) {
			push( @ready, $p );
		}
	}

	do_log( "[READYPERLS] Found " . scalar @ready . " perls ready to smoke" );

	return \@ready;
}

sub prompt_perlmatrix {
	my $res = prompt( "Compile the perl matrix", 'y', 10, 1 );
	if ( lc( $res ) eq 'y' ) {
		$domatrix = 1;
	} else {
		$domatrix = 0;
	}

	return;
}

sub reset_logs {
	@LOGS = ();
	return;
}

sub save_logs {
	my $end = shift;

	# Make sure we don't overwrite logs
	if ( -e "$PATH/perls/perl-$perlver-$perlopts.$end" ) {
		print "[LOGS] Skipping log save of '$PATH/perls/perl-$perlver-$perlopts.$end' as it already exists\n";
	} else {
		do_log( "[LOGS] Saving log to '$PATH/perls/perl-$perlver-$perlopts.$end'" );
		open( my $log, '>', "$PATH/perls/perl-$perlver-$perlopts.$end" ) or die "Unable to create log: $!";
		foreach my $l ( @LOGS ) {
			print $log "$l\n";
		}
		close( $log ) or die "Unable to close log: $!";
	}

	return;
}

sub do_log {
	my $line = shift;

	print $line . "\n";
	push( @LOGS, $line );
	return;
}

sub get_CPANPLUS_ver {
	# is the "cpan" user's CPANPLUS configured?
	do_config_localCPANPLUS();

	# TODO disabled, because it consumed gobs of RAM unnecessarily...
#	require CPANPLUS::Backend;
#	my $cb = CPANPLUS::Backend->new;
#	my $mod = $cb->module_tree( "CPANPLUS" );
#	my $ver = defined $mod ? $mod->package_version : undef;
#	if ( defined $ver ) {
#		return $ver;
#	} else {
		# the default
		return "0.88";
#	}
}

sub do_config_localCPANPLUS {
	# configure the local user Config settings
	my $uconfig = <<'END';
###############################################
###
###  Configuration structure for CPANPLUS::Config::User
###
###############################################

#last changed: Sun Mar  1 10:56:52 2009 GMT

### minimal pod, so you can find it with perldoc -l, etc
=pod

=head1 NAME

CPANPLUS::Config::User

=head1 DESCRIPTION

This is a CPANPLUS configuration file. Editing this
config changes the way CPANPLUS will behave

=cut

package CPANPLUS::Config::User;

use strict;

sub setup {
	my $conf = shift;

	### conf section
	$conf->set_conf( allow_build_interactivity => 0 );
	$conf->set_conf( base => 'XXXHOMEXXX/.cpanplus' );
	$conf->set_conf( buildflags => '' );
	$conf->set_conf( cpantest => 1 );
	$conf->set_conf( cpantest_mx => '' );
	$conf->set_conf( cpantest_reporter_args => {
		transport => 'HTTPGateway',
		transport_args => [ 'http://192.168.0.200:11111/submit' ],
	} );
	$conf->set_conf( debug => 0 );
	$conf->set_conf( dist_type => '' );
	$conf->set_conf( email => 'perl@0ne.us' );
	$conf->set_conf( enable_custom_sources => 0 );
	$conf->set_conf( extractdir => '' );
	$conf->set_conf( fetchdir => '' );
	$conf->set_conf( flush => 1 );
	$conf->set_conf( force => 0 );
	$conf->set_conf( hosts => [
		{
			'path' => '/CPAN/',
			'scheme' => 'ftp',
			'host' => '192.168.0.200',
		},
	] );
	$conf->set_conf( lib => [] );
	$conf->set_conf( makeflags => '' );
	$conf->set_conf( makemakerflags => '' );
	$conf->set_conf( md5 => 1 );
	$conf->set_conf( no_update => 1 );
	$conf->set_conf( passive => 1 );
	$conf->set_conf( prefer_bin => 0 );
	$conf->set_conf( prefer_makefile => 1 );
	$conf->set_conf( prereqs => 1 );
	$conf->set_conf( shell => 'CPANPLUS::Shell::Default' );
	$conf->set_conf( show_startup_tip => 0 );
	$conf->set_conf( signature => 0 );
	$conf->set_conf( skiptest => 0 );
	$conf->set_conf( source_engine => 'CPANPLUS::Internals::Source::Memory' );
	$conf->set_conf( storable => 1 );
	$conf->set_conf( timeout => 300 );
	$conf->set_conf( verbose => 1 );
	$conf->set_conf( write_install_logs => 0 );

	### program section
	$conf->set_program( editor => 'XXXWHICH-nanoXXX' );
	$conf->set_program( make => 'XXXWHICH-makeXXX' );
	$conf->set_program( pager => 'XXXWHICH-lessXXX' );
	$conf->set_program( perlwrapper => 'XXXWHICH-cpanp-run-perlXXX' );
	$conf->set_program( shell => 'XXXWHICH-bashXXX' );
	$conf->set_program( sudo => undef );

	return 1;
}

1;
END

	# okay, look at the default CPANPLUS config location
	if ( ! -e "$ENV{HOME}/.cpanplus/lib/CPANPLUS/Config/User.pm" ) {
		do_log( "[CPANPLUS] Configuring the local user's CPANPLUS config..." );

		# transform the XXXargsXXX
		$uconfig = do_replacements( $uconfig );

		# save it!
		# TODO use File::Path::Tiny
		do_shellcommand( "mkdir -p $ENV{HOME}/.cpanplus/lib/CPANPLUS/Config" );
		open( my $config, '>', "$ENV{HOME}/.cpanplus/lib/CPANPLUS/Config/User.pm" ) or die "unable to create config: $!";
		print $config $uconfig;
		close( $config );

		# force an update
		# we don't use do_cpanp_action() here because we need to use the local user's CPANPLUS config not the boxed one...
		do_shellcommand( "APPDATA=$ENV{HOME}/ cpanp x --update_source" );
	}

	return;
}

sub prompt_debug {
	my $res = prompt( "Turn on debugging", 'y', 10, 1 );
	if ( lc( $res ) eq 'y' ) {
		$DEBUG = 1;
	}

	return;
}

# prompt the user for perl version
sub prompt_perlver {
	# get our perl tarballs
	@perls = @{ getPerlVersions() };

	my $res;
	while ( ! defined $res ) {
		$res = prompt( "Which perl version to compile [ver/d/a]", $perls[-1], 10, 1 );
		if ( lc( $res ) eq 'd' ) {
			# display available versions
			print "Available Perls: " . join( ' ', @perls ) . "\n";
			$res = undef;
		} elsif ( lc( $res ) eq 'a' ) {
			return 'a';
		} else {
			# make sure the version exists
			if ( ! grep { $_ eq $res } @perls ) {
				print "Selected version doesn't exist, please try again.\n";
				$res = undef;
			} else {
				return $res;
			}
		}
	}

	return;
}

# gets the perls
sub getPerlVersions {
	# do we even have a build dir?
	get_perl_tarballs();

	my @perls;
	opendir( PERLS, $PATH . '/build' ) or die "Unable to opendir: $@";
	@perls = sort versioncmp map { $_ =~ /^perl\-([\d\.]+)\./; $_ = $1; } grep { /^perl\-[\d\.]+\.tar\.gz$/ && -f "$PATH/build/$_"  } readdir( PERLS );
	closedir( PERLS ) or die "Unable to closedir: $@";

	return \@perls;
}

sub get_perl_tarballs {
	if ( ! -d "$PATH/build" ) {
		# automatically get the perl tarballs?
		my $res = prompt( "Do you want me to automatically get the perl tarballs", 'y', 10, 1 );
		if ( lc( $res ) eq 'y' ) {
			do_log( "[GETPERLS] mkdir '$PATH/build'" );
			mkdir( "$PATH/build" ) or die "Unable to mkdir: $!";

			# TODO get rid of all_perls.tar.gz and download individually?
			do_shellcommand( "wget ftp://192.168.0.200/perl_dists/src/all_perls.tar.gz" );
			do_shellcommand( "tar -C $PATH/build -xf all_perls.tar.gz" );
			do_log( "[GETPERLS] unlink 'all_perls.tar.gz'" );
			unlink( 'all_perls.tar.gz' ) or die "Unable to unlink: $!";

			# make the perls directory
			if ( ! -d "$PATH/perls" ) {
				do_log( "[GETPERLS] mkdir '$PATH/perls'" );
				mkdir( "$PATH/perls" ) or die "Unable to mkdir: $!";
			}
		} else {
			do_log( "[COMPILER] No perl tarballs available..." );
			exit;
		}
	}

	return;
}

sub install_perl {
	my $perl = shift;

	reset_logs();

	# Skip problematic perls
	# TODO make this configurable
	if ( $perlver eq '5.6.0' or $perlver eq '5.8.0' ) {
		# CPANPLUS won't work on 5.6.0, also some modules we want to install doesn't like 5.6.x :(
		# <Apocalypse> Yeah wish me luck, last year I managed to get 5.6.0 built but couldn't get CPANPLUS to install on it
		# <Apocalypse> Maybe the situation is better now - I'm working downwards so I'll hit 5.6.X sometime later tonite after I finish 5.8.5, 5.8.4, and so on :)
		# <@kane> 5.6.1 is the minimum
		# <Apocalypse> Ah, so CPANPLUS definitely won't work on 5.6.0? I should just drop it...

		# 5.8.0 blows up horribly in it's tests everywhere I try to compile it...
		do_log( "[PERLBUILDER] Skipping perl-$perlver because of known problems..." );
		return;
	}

	# build a default build
	if ( ! build_perl_opts( $perl, 'default' ) ) {
		save_logs( 'fail' );
	} else {
#		save_logs( 'ok' );
	}

	# Should we also compile the matrix?
	if ( $domatrix ) {
		reset_logs();

		# loop over all the options we have
		# TODO use hints to figure out if this is 64bit or 32bit OS
		foreach my $thr ( qw( thr nothr ) ) {
			foreach my $multi ( qw( multi nomulti ) ) {
				foreach my $long ( qw( long nolong ) ) {
					foreach my $malloc ( qw( mymalloc nomymalloc ) ) {
						foreach my $bitness ( qw( 32 64i 64a ) ) {
							if ( ! build_perl_opts( $perl, $thr . '-' . $multi . '-' . $long . '-' . $malloc . '-' . $bitness ) ) {
								save_logs( 'fail' );
							} else {
#								save_logs( 'ok' );
							}

							reset_logs();
						}
					}
				}
			}
		}
	}

	return;
}

sub build_perl_opts {
	# set the perl stuff
	( $perlver, $perlopts ) = @_;

	# ignore the args for now, as we use globals :(
	do_log( "[PERLBUILDER] Preparing to build perl-$perlver-$perlopts" );

	# have we already compiled+installed this version?
	if ( ! -d "$PATH/perls/perl-$perlver-$perlopts" ) {
		# did the compile fail?
		if ( -e "$PATH/perls/perl-$perlver-$perlopts.fail" ) {
			do_log( "[PERLBUILDER] perl-$perlver-$perlopts already failed, skipping..." );
			return 0;
		}

		# kick off the build process!
		my $ret = do_build();

		# cleanup the build dir ( lots of space! )
		# TODO use File::Path::Tiny
		do_shellcommand( "rm -rf $PATH/build/perl-$perlver-$perlopts" );

		if ( ! $ret ) {
			# failed something during compiling, move on!
			return 0;
		}
	} else {
		# all done with configuring?
		if ( -e "$PATH/perls/perl-$perlver-$perlopts/ready.smoke" ) {
			do_log( "[PERLBUILDER] perl-$perlver-$perlopts is ready to smoke..." );
			return 1;
		} else {
			do_log( "[PERLBUILDER] perl-$perlver-$perlopts is already built..." );
		}
	}

	# do we have CPANPLUS already extracted?
	if ( ! do_initCPANP_BOXED() ) {
		return 0;
	}

	# we go ahead and configure CPANPLUS for this version :)
	if ( ! do_installCPANPLUS() ) {
		return 0;
	}

	# configure CPAN so some stupid modules don't try to use it... /me looks at old Module::Install !!
	# TODO we forget about CPAN for now, because it is unnecessary and keeps blowing up Term::ReadLine::Perl somehow...

	# move on with the test stuff
	if ( ! do_installCPANTesters() ) {
		return 0;
	}

	# finalize the perl install!
	if ( ! finalize_perl() ) {
		return 0;
	}

	# we're done!
	return 1;
}

sub finalize_perl {
	# thanks to BiNGOs for the idea!
	# TODO annoying to do it for each run...
	#do_shellcommand( "sudo chown -R root:root $PATH/perls/perl-$perlver-$perlopts" );

	# Get rid of the man directories!
	do_shellcommand( "rm -rf $PATH/perls/perl-$perlver-$perlopts/man" );

	# we're really done!
	do_shellcommand( "touch $PATH/perls/perl-$perlver-$perlopts/ready.smoke" );

	return 1;
}

sub do_prebuild {
	if ( -d "$PATH/build/perl-$perlver-$perlopts" ) {
		# remove it so we have a consistent build process
		# TODO use File::Path::Tiny
		do_shellcommand( "rm -rf $PATH/build/perl-$perlver-$perlopts" );
	}

	# make sure we have the output dir ready
	if ( ! -d "$PATH/perls" ) {
		do_log( "[PERLBUILDER] mkdir '$PATH/perls'" );
		mkdir( "$PATH/perls" ) or die "Unable to mkdir: $!";
	}

	# extract the tarball!
	do_shellcommand( "tar -C $PATH/build -zxf $PATH/build/perl-$perlver.tar.gz" );
	do_shellcommand( "mv $PATH/build/perl-$perlver $PATH/build/perl-$perlver-$perlopts" );

	# reset the patch counter
	do_patch_reset();

	# now, apply the patches each version needs
	do_prebuild_patches();

	# TODO this sucks, but lib/Benchmark.t usually takes forever and fails unnecessarily on my loaded box...
	if ( -f "$PATH/build/perl-$perlver-$perlopts/lib/Benchmark.t" ) {
		do_log( "[PERLBUILDER] Removing problematic Benchmark.t test" );
		unlink( "$PATH/build/perl-$perlver-$perlopts/lib/Benchmark.t" ) or die "Unable to unlink: $!";

		# argh, we have to munge MANIFEST
		do_shellcommand( "perl -nli -e 'print if ! /^lib\\/Benchmark\\.t/' $PATH/build/perl-$perlver-$perlopts/MANIFEST" );
	}

	return;
}

sub do_initCPANP_BOXED {
	do_log( "[CPANPLUS] Configuring CPANPLUS::Boxed..." );

	# Get the cpanplus version
	$CPANPLUS_ver = get_CPANPLUS_ver() if ! defined $CPANPLUS_ver;

	# do we have CPANPLUS already extracted?
	if ( -d "$PATH/CPANPLUS-$CPANPLUS_ver" ) {
		# cleanup the cruft
		opendir( CPANPLUS, "$PATH/CPANPLUS-$CPANPLUS_ver/.cpanplus/$ENV{USER}" ) or die "Unable to opendir: $!";
		my @dirlist = readdir( CPANPLUS );
		closedir( CPANPLUS ) or die "Unable to closedir: $!";

		# look for perl versions of build directory
		# /export/home/cpan/CPANPLUS-0.88/.cpanplus/cpan/5.10.0
		@dirlist = grep { /^\d+\.\d+\.\d+$/ } @dirlist;
		foreach my $d ( @dirlist ) {
			# TODO use File::Path::Tiny
			do_shellcommand( "rm -rf $PATH/CPANPLUS-$CPANPLUS_ver/.cpanplus/$ENV{USER}/$d" );
		}
	} else {
		# do we have the tarball?
		if ( ! -f "$PATH/CPANPLUS-$CPANPLUS_ver.tar.gz" ) {
			# get it!
			# TODO the author might change... waht's a portable way?
			do_shellcommand( "wget ftp://192.168.0.200/CPAN/authors/id/K/KA/KANE/CPANPLUS-$CPANPLUS_ver.tar.gz" );
		}

		# extract it!
		do_shellcommand( "tar -zxf $PATH/CPANPLUS-$CPANPLUS_ver.tar.gz" );

		# configure the Boxed.pm file
		do_installCPANP_BOXED_config();

		# force an update
		if ( ! do_cpanpboxed_action( "x --update_source" ) ) {
			return 0;
		}
	}

	return 1;
}

sub do_installCPANP_BOXED_config {
	# configure the Boxed Config settings
	my $boxed = <<'END';
##############################################
###
###  Configuration structure for CPANPLUS::Config::Boxed
###
###############################################

#last changed: Sun Mar  1 10:56:52 2009 GMT

### minimal pod, so you can find it with perldoc -l, etc
=pod

=head1 NAME

CPANPLUS::Config::Boxed

=head1 DESCRIPTION

This is a CPANPLUS configuration file. Editing this
config changes the way CPANPLUS will behave

=cut

package CPANPLUS::Config::Boxed;

use strict;

sub setup {
	my $conf = shift;

	### conf section
	$conf->set_conf( allow_build_interactivity => 0 );
	$conf->set_conf( base => 'XXXPATHXXX/CPANPLUS-XXXCPANPLUSXXX/.cpanplus/XXXUSERXXX' );
	$conf->set_conf( buildflags => '' );
	$conf->set_conf( cpantest => 0 );
	$conf->set_conf( cpantest_mx => '' );
	$conf->set_conf( cpantest_reporter_args => {} );
	$conf->set_conf( debug => 0 );
	$conf->set_conf( dist_type => '' );
	$conf->set_conf( email => 'perl@0ne.us' );
	$conf->set_conf( enable_custom_sources => 0 );
	$conf->set_conf( extractdir => '' );
	$conf->set_conf( fetchdir => '' );
	$conf->set_conf( flush => 1 );
	$conf->set_conf( force => 0 );
	$conf->set_conf( hosts => [
		{
			'path' => '/CPAN/',
			'scheme' => 'ftp',
			'host' => '192.168.0.200',
		},
	] );
	$conf->set_conf( lib => [] );
	$conf->set_conf( makeflags => '' );
	$conf->set_conf( makemakerflags => '' );
	$conf->set_conf( md5 => 1 );
	$conf->set_conf( no_update => 1 );
	$conf->set_conf( passive => 1 );
	$conf->set_conf( prefer_bin => 0 );
	$conf->set_conf( prefer_makefile => 1 );
	$conf->set_conf( prereqs => 1 );
	$conf->set_conf( shell => 'CPANPLUS::Shell::Default' );
	$conf->set_conf( show_startup_tip => 0 );
	$conf->set_conf( signature => 0 );
	$conf->set_conf( skiptest => 1 );
	$conf->set_conf( source_engine => 'CPANPLUS::Internals::Source::Memory' );
	$conf->set_conf( storable => 1 );
	$conf->set_conf( timeout => 300 );
	$conf->set_conf( verbose => 1 );
	$conf->set_conf( write_install_logs => 0 );

	### program section
	$conf->set_program( editor => 'XXXWHICH-nanoXXX' );
	$conf->set_program( make => 'XXXWHICH-makeXXX' );
	$conf->set_program( pager => 'XXXWHICH-lessXXX' );
	$conf->set_program( perlwrapper => 'XXXPATHXXX/CPANPLUS-XXXCPANPLUSXXX/bin/cpanp-run-perl' );
	$conf->set_program( shell => 'XXXWHICH-bashXXX' );
	$conf->set_program( sudo => undef );

	return 1;
}

1;
END

	# transform the XXXargsXXX
	$boxed = do_replacements( $boxed );

	# save it!
	# TODO use File::Path::Tiny
	do_shellcommand( "mkdir -p $PATH/CPANPLUS-$CPANPLUS_ver/.cpanplus/$ENV{USER}/lib/CPANPLUS/Config" );
	open( my $config, '>', "$PATH/CPANPLUS-$CPANPLUS_ver/.cpanplus/$ENV{USER}/lib/CPANPLUS/Config/Boxed.pm" ) or die "Unable to create config: $!";
	print $config $boxed;
	close( $config ) or die "Unable to close config: $!";

	return;
}

sub do_replacements {
	my $str = shift;

	# basic stuff
	$str =~ s/XXXHOMEXXX/$ENV{HOME}/g;
	$str =~ s/XXXUSERXXX/$ENV{USER}/g;
	$str =~ s/XXXPATHXXX/$PATH/g;
	$str =~ s/XXXCPANPLUSXXX/$CPANPLUS_ver/g;
	$str =~ s/XXXPERLVERXXX/$perlver-$perlopts/g;

	# find binary locations
	$str =~ s/XXXWHICH-([\w\-]+)XXX/get_binary_path( $1 )/ge;

	return $str;
}

sub get_binary_path {
	my $binary = shift;

	# TODO use File::Which
	my $path = `which $binary`;
	if ( defined $path ) {
		chomp( $path );
		return $path;
	} else {
		return '';
	}
}

sub do_installCPANPLUS {
	do_log( "[CPANPLUS] Configuring CPANPLUS..." );

	# use cpanp-boxed to install some modules that we know we need to bootstrap, argh! ( cpanp-boxed already skips tests so this should be fast )
	# perl-5.6.1 -> ExtUtils::MakeMaker, Test::More, File::Temp, Time::HiRes
	# Module::Build -> ExtUtils::CBuilder, ExtUtils::ParseXS
	# LWP on perl-5.8.2 bombs on Encode
	# Test::Reporter::HTTPGateway -> LWP::UserAgent ( missing prereq, wow! )
	if ( ! do_cpanpboxed_action( "i ExtUtils::MakeMaker ExtUtils::CBuilder ExtUtils::ParseXS Test::More File::Temp Time::HiRes Encode LWP::UserAgent" ) ) {
		return 0;
	}

	# Install CPANPLUS and it's stuff!
	if ( ! do_cpanpboxed_action( "s selfupdate all" ) ) {
		return 0;
	}

	# configure the installed CPANPLUS
	do_installCPANPLUS_config();

	# force an update
	do_cpanp_action( "perl-$perlver-$perlopts", "x --update_source" );

	return 1;
}

sub do_installCPANPLUS_config {
	# configure the CPANPLUS config
	my $cpanplus = <<'END';
###############################################
###
###  Configuration structure for CPANPLUS::Config::User
###
###############################################

#last changed: Sun Mar  1 10:56:52 2009 GMT

### minimal pod, so you can find it with perldoc -l, etc
=pod

=head1 NAME

CPANPLUS::Config::User

=head1 DESCRIPTION

This is a CPANPLUS configuration file. Editing this
config changes the way CPANPLUS will behave

=cut

package CPANPLUS::Config::User;

use strict;

sub setup {
	my $conf = shift;

	### conf section
	$conf->set_conf( allow_build_interactivity => 0 );
	$conf->set_conf( base => 'XXXPATHXXX/cpanp_conf/perl-XXXPERLVERXXX/.cpanplus' );
	$conf->set_conf( buildflags => '' );
	$conf->set_conf( cpantest => 1 );
	$conf->set_conf( cpantest_mx => '' );
	$conf->set_conf( cpantest_reporter_args => {
		transport => 'HTTPGateway',
		transport_args => [ 'http://192.168.0.200:11111/submit' ],
	} );
	$conf->set_conf( debug => 0 );
	$conf->set_conf( dist_type => '' );
	$conf->set_conf( email => 'perl@0ne.us' );
	$conf->set_conf( enable_custom_sources => 0 );
	$conf->set_conf( extractdir => '' );
	$conf->set_conf( fetchdir => '' );
	$conf->set_conf( flush => 1 );
	$conf->set_conf( force => 0 );
	$conf->set_conf( hosts => [
		{
			'path' => '/CPAN/',
			'scheme' => 'ftp',
			'host' => '192.168.0.200',
		},
	] );
	$conf->set_conf( lib => [] );
	$conf->set_conf( makeflags => '' );
	$conf->set_conf( makemakerflags => '' );
	$conf->set_conf( md5 => 1 );
	$conf->set_conf( no_update => 1 );
	$conf->set_conf( passive => 1 );
	$conf->set_conf( prefer_bin => 0 );
	$conf->set_conf( prefer_makefile => 1 );
	$conf->set_conf( prereqs => 1 );
	$conf->set_conf( shell => 'CPANPLUS::Shell::Default' );
	$conf->set_conf( show_startup_tip => 0 );
	$conf->set_conf( signature => 0 );
	$conf->set_conf( skiptest => 0 );
	$conf->set_conf( source_engine => 'CPANPLUS::Internals::Source::Memory' );
	$conf->set_conf( storable => 1 );
	$conf->set_conf( timeout => 300 );
	$conf->set_conf( verbose => 1 );
	$conf->set_conf( write_install_logs => 0 );

	### program section
	$conf->set_program( editor => 'XXXWHICH-nanoXXX' );
	$conf->set_program( make => 'XXXWHICH-makeXXX' );
	$conf->set_program( pager => 'XXXWHICH-lessXXX' );
	$conf->set_program( perlwrapper => 'XXXPATHXXX/perls/perl-XXXPERLVERXXX/bin/cpanp-run-perl' );
	$conf->set_program( shell => 'XXXWHICH-bashXXX' );
	$conf->set_program( sudo => undef );

	return 1;
}

1;
END

	# transform the XXXargsXXX
	$cpanplus = do_replacements( $cpanplus );

	# save it!
	# TODO use File::Path::Tiny
	do_shellcommand( "mkdir -p $PATH/cpanp_conf/perl-$perlver-$perlopts/.cpanplus/lib/CPANPLUS/Config" );
	open( my $config, '>', "$PATH/cpanp_conf/perl-$perlver-$perlopts/.cpanplus/lib/CPANPLUS/Config/User.pm" ) or die "Unable to create config: $!";
	print $config $cpanplus;
	close( $config ) or die "Unable to close config: $!";

	return;
}

sub do_cpanpboxed_action {
	my $action = shift;

	# use default answer to prompts ( MakeMaker stuff - PERL_MM_USE_DEFAULT )
	my $ret = do_shellcommand( "PERL_MM_USE_DEFAULT=1 $PATH/perls/perl-$perlver-$perlopts/bin/perl $PATH/CPANPLUS-$CPANPLUS_ver/bin/cpanp-boxed $action" );

	return analyze_cpanp_install( $action, $ret );
}

sub analyze_cpanp_install {
	my( $action, $ret ) = @_;

	if ( $action =~ /^i/ ) {
		#	root@blackhole:/home/apoc# cpanp i DBI
		#	Installing DBI (1.609)
		#	[MSG] Module 'DBI' already up to date, won't install without force
		#	Module 'DBI' installed successfully
		#	No errors installing all modules
		#
		#	root@blackhole:/home/apoc#
		if ( $ret->[-1] =~ /No\s+errors\s+installing\s+all\s+modules/ ) {
			return 1;
		} else {
			return 0;
		}
	} elsif ( $action =~ /^s/ ) {
		# TODO analyse this?
		return 1;
	} elsif ( $action =~ /^x/ ) {
		# always succeeds
		return 1;
	}
}

sub do_cpanp_action {
	my $perl = shift;
	my $action = shift;

	# use default answer to prompts ( MakeMaker stuff - PERL_MM_USE_DEFAULT )
	my $ret = do_shellcommand( "PERL_MM_USE_DEFAULT=1 APPDATA=$PATH/cpanp_conf/$perl/ $PATH/perls/$perl/bin/perl $PATH/perls/$perl/bin/cpanp $action" );

	return analyze_cpanp_install( $action, $ret );
}

sub do_installCPANTesters {
	do_log( "[CPANPLUS] Configuring CPANTesters..." );

	# install the basic modules we need
	if ( ! do_cpanpboxed_action( "i Test::Reporter CPANPLUS::YACSmoke" ) ) {
		return 0;
	}

	return 1;
}

sub do_shellcommand {
	my $cmd = shift;

	do_log( "[SHELLCMD] Executing $cmd" );
	my $output;
	if ( $DEBUG ) {
		$output = tee_merged { system( $cmd ) };
	} else {
		$output = capture_merged { system( $cmd ) };
	}
	my @output = split( /\n/, $output );
	push( @LOGS, @output );
	return \@output;
}

sub do_build {
	# do prebuild stuff
	do_prebuild();

	# we start off with the Configure step
	my $extraoptions = '';
	if ( $perlver =~ /^5\.(\d+)\./ ) {
		my $v = $1;

		# Are we running a devel version?
		if ( $v % 2 != 0 ) {
			$extraoptions .= ' -Dusedevel -Uversiononly';
		} elsif ( $v == 6 or $v == 8 ) {
			# disable DB_File support ( buggy )
			$extraoptions .= ' -Ui_db';
		}
	}

	# parse the perlopts
	if ( defined $perlopts ) {
		if ( $perlopts =~ /nothr/ ) {
			$extraoptions .= ' -Uusethreads';
		} elsif ( $perlopts =~ /thr/ ) {
			$extraoptions .= ' -Dusethreads';
		}

		if ( $perlopts =~ /nomulti/ ) {
			$extraoptions .= ' -Uusemultiplicity';
		} elsif ( $perlopts =~ /multi/ ) {
			$extraoptions .= ' -Dusemultiplicity';
		}

		if ( $perlopts =~ /nolong/ ) {
			$extraoptions .= ' -Uuselongdouble';
		} elsif ( $perlopts =~ /long/ ) {
			$extraoptions .= ' -Duselongdouble';
		}

		if ( $perlopts =~ /nomymalloc/ ) {
			$extraoptions .= ' -Uusemymalloc';
		} elsif ( $perlopts =~ /mymalloc/ ) {
			$extraoptions .= ' -Dusemymalloc';
		}

		if ( $perlopts =~ /64a/ ) {
			$extraoptions .= ' -Duse64bitall';
		} elsif ( $perlopts =~ /64i/ ) {
			$extraoptions .= ' -Duse64bitint';
		} elsif ( $perlopts =~ /32/ ) {
			$extraoptions .= ' -Uuse64bitall -Uuse64bitint';
		}
	}

	# actually do the configure!
	do_shellcommand( "cd $PATH/build/perl-$perlver-$perlopts; sh Configure -des -Dprefix=$PATH/perls/perl-$perlver-$perlopts $extraoptions" );

	# generate dependencies - not needed because Configure -des defaults to automatically doing it
	#do_shellcommand( "cd build/perl-$perlver-$perlopts; make depend" );

	# actually compile!
	my $output = do_shellcommand( "cd $PATH/build/perl-$perlver-$perlopts; make" );
	if ( $output->[-1] !~ /to\s+run\s+test\s+suite/ ) {
		do_log( "[PERLBUILDER] Unable to compile perl-$perlver-$perlopts!" );
		return 0;
	}

	# make sure we pass tests
	$output = do_shellcommand( "cd $PATH/build/perl-$perlver-$perlopts; make test" );
	if ( ! grep { /^All\s+tests\s+successful\.$/ } @$output ) {
		# Is it ok to proceed?
		if ( ! check_perl_test( $output ) ) {
			do_log( "[PERLBUILDER] Testsuite failed for perl-$perlver-$perlopts!" );
			return 0;
		}
	}

	# okay, do the install!
	do_shellcommand( "cd $PATH/build/perl-$perlver-$perlopts; make install" );

	# all done!
	do_log( "[PERLBUILDER] Installed perl-$perlver-$perlopts successfully!" );
	return 1;
}

# checks for "allowed" test failures ( known problems )
sub check_perl_test {
	my $output = shift;

	# TODO argh, file::find often fails, need to track down why it happens
	if ( grep { /^Failed\s+1\s+test/ } @$output and grep { m|^lib/File/Find/t/find\.+FAILED| } @$output ) {
		do_log( "[PERLBUILDER] Detected File::Find test failure, ignoring it..." );
		return 1;
	}

	# 5.8.8 has known problems with sprintf.t and sprintf2.t
	#t/op/sprintf..............................FAILED--no leader found
	#t/op/sprintf2.............................FAILED--expected 263 tests, saw 3
	if ( $perlver eq '5.8.8' and grep { /^Failed\s+2\s+test/ } @$output and grep { m|^t/op/sprintf\.+FAILED| } @$output ) {
		do_log( "[PERLBUILDER] Detected sprintf test failure on 5.8.8, ignoring it..." );
		return 1;
	}

	# Unknown failure!
	return 0;
}

sub do_prebuild_patches {
	# okay, what version is this?
	if ( $perlver =~ /^5\.8\.(\d+)$/ ) {
		my $v = $1;
		if ( $v == 0 or $v == 1 or $v == 2 or $v == 3 or $v == 4 or $v == 5 or $v == 6 or $v == 7 or $v == 8 ) {
			# fix asm/page.h error
			patch_asmpageh();

			patch_makedepend_escape();

			patch_makedepend_cleanups_58x();
		}
	} elsif ( $perlver =~ /^5\.6\.(\d+)$/ ) {
		my $v = $1;

		# fix asm/page.h error
		patch_asmpageh();

		# the Configure script is buggy in detecting signals
		patch_Configure_signals();

		patch_makedepend_escape();
		if ( $v == 2 ) {
			patch_makedepend_cleanups_562();
		} elsif ( $v == 1 ) {
			patch_makedepend_cleanups_561();
		} elsif ( $v == 0 ) {
			patch_makedepend_cleanups_560();
		}
	}

	# Patch some files per-OS
	if ( $^O eq 'netbsd' ) {
		patch_hints_netbsd();
	} elsif ( $^O eq 'freebsd' ) {
		patch_hints_freebsd();
	}
}

{
	my $patch_num;
	sub do_patch {
		my( $patchdata ) = @_;

		# okay, apply it!
		open( my $patch, '>', "$PATH/build/perl-$perlver-$perlopts/patch.$patch_num" ) or die "Unable to create patchfile: $!";
		print $patch $patchdata;
		close( $patch ) or die "Unable to close patchfile: $!";

		do_shellcommand( "patch -p0 -d $PATH/build/perl-$perlver-$perlopts < $PATH/build/perl-$perlver-$perlopts/patch.$patch_num" );
#		unlink("build/perl-$perlver-$perlopts/patch.$patch_num") or die "unable to unlink patchfile: $@";
		$patch_num++;

		return 1;
	}

	sub do_patch_reset {
		$patch_num = 0;
		return;
	}
}

sub patch_asmpageh {
	# from http://www.nntp.perl.org/group/perl.perl5.porters/2007/08/msg127609.html
	# updated from http://www.nntp.perl.org/group/perl.perl5.porters/2009/03/msg145182.html
	my $data = <<'EOF';
--- ext/IPC/SysV/SysV.xs.orig	2009-11-14 21:27:40.668648136 -0700
+++ ext/IPC/SysV/SysV.xs	2009-11-14 21:29:06.180359572 -0700
@@ -3,9 +3,6 @@
 #include "XSUB.h"

 #include <sys/types.h>
-#ifdef __linux__
-#   include <asm/page.h>
-#endif
 #if defined(HAS_MSG) || defined(HAS_SEM) || defined(HAS_SHM)
 #ifndef HAS_SEM
 #   include <sys/ipc.h>
@@ -21,7 +18,10 @@
 #      ifndef HAS_SHMAT_PROTOTYPE
            extern Shmat_t shmat (int, char *, int);
 #      endif
-#      if defined(__sparc__) && (defined(__NetBSD__) || defined(__OpenBSD__))
+#      if defined(HAS_SYSCONF) && defined(_SC_PAGESIZE)
+#          undef  SHMLBA /* not static: determined at boot time */
+#          define SHMLBA sysconf(_SC_PAGESIZE)
+#      elif defined(HAS_GETPAGESIZE)
 #          undef  SHMLBA /* not static: determined at boot time */
 #          define SHMLBA getpagesize()
 #      endif
EOF

	# okay, apply it!
	return do_patch( $data );
}

sub patch_makedepend_cleanups_562 {
	# from http://perl5.git.perl.org/perl.git/commitdiff/2bce232
	my $data = <<'EOF';
--- makedepend.SH.orig
+++ makedepend.SH
@@ -163,6 +163,7 @@
 	    -e '/^#.*<builtin>/d' \
 	    -e '/^#.*<built-in>/d' \
 	    -e '/^#.*<command line>/d' \
+	    -e '/^#.*<command-line>/d' \
 	    -e '/^#.*"-"/d' \
 	    -e 's#\.[0-9][0-9]*\.c#'"$file.c#" \
 	    -e 's/^[     ]*#[    ]*line/#/' \
EOF

	# okay, apply it!
	return do_patch( $data );
}

sub patch_makedepend_cleanups_58x {
	my $data = <<'EOF';
--- makedepend.SH.orig	2009-11-16 22:09:17.328115128 -0700
+++ makedepend.SH	2009-11-16 22:10:12.808109304 -0700
@@ -167,6 +167,7 @@
             -e '/^#.*<builtin>/d' \
             -e '/^#.*<built-in>/d' \
             -e '/^#.*<command line>/d' \
+            -e '/^#.*<command-line>/d' \
 	    -e '/^#.*"-"/d' \
 	    -e '/: file path prefix .* never used$/d' \
 	    -e 's#\.[0-9][0-9]*\.c#'"$file.c#" \
EOF

	# okay, apply it!
	return do_patch( $data );
}

sub patch_makedepend_cleanups_561 {
	# from http://perl5.git.perl.org/perl.git/commitdiff/2bce232
	my $data = <<'EOF';
--- makedepend.SH.orig
+++ makedepend.SH
@@ -154,6 +154,10 @@
         $cppstdin $finc -I. $cppflags $cppminus <UU/$file.c |
         $sed \
 	    -e '1d' \
+	    -e '/^#.*<builtin>/d' \
+	    -e '/^#.*<built-in>/d' \
+	    -e '/^#.*<command line>/d' \
+	    -e '/^#.*<command-line>/d' \
 	    -e '/^#.*<stdin>/d' \
 	    -e '/^#.*"-"/d' \
 	    -e 's#\.[0-9][0-9]*\.c#'"$file.c#" \
EOF

	# okay, apply it!
	return do_patch( $data );
}

sub patch_makedepend_cleanups_560 {
	# from http://perl5.git.perl.org/perl.git/commitdiff/2bce232
	my $data = <<'EOF';
--- makedepend.SH.orig
+++ makedepend.SH
@@ -136,6 +136,10 @@
     $cppstdin $finc -I. $cppflags $cppminus <UU/$file.c |
     $sed \
 	-e '1d' \
+	-e '/^#.*<builtin>/d' \
+	-e '/^#.*<built-in>/d' \
+	-e '/^#.*<command line>/d' \
+	-e '/^#.*<command-line>/d' \
 	-e '/^#.*<stdin>/d' \
 	-e '/^#.*"-"/d' \
 	-e 's#\.[0-9][0-9]*\.c#'"$file.c#" \
EOF

	# okay, apply it!
	return do_patch( $data );
}

sub patch_makedepend_escape {
	# from http://perl5.git.perl.org/perl.git/commitdiff/a9ff62c8
	my $data = <<'EOF';
--- makedepend.SH.orig
+++ makedepend.SH
@@ -126,7 +126,7 @@
     *.y) filebase=`basename $file .y` ;;
     esac
     case "$file" in
-    */*) finc="-I`echo $file | sed 's#/[^/]*$##`" ;;
+    */*) finc="-I`echo $file | sed 's#/[^/]*$##'`" ;;
     *)   finc= ;;
     esac
     $echo "Finding dependencies for $filebase$_o."
EOF

	# okay, apply it!
	return do_patch( $data );
}

sub patch_Configure_signals {
	# <Apocalypse> The following 1 signals are available: SIGZERO
	# <Apocalypse> funny heh
	# <Apocalypse> /usr/bin/sort: open failed: +1: No such file or directory
	# <Bram> Hmm. That could be a problem with a newer version of sort.. I remember seeing a Change of it a long time ago but again don't fully remember...
	# <Bram> In Configure (on 5.6.1): replace the first  $sort -n +1  with:  ($sort -n -k 2 2>/dev/null || $sort -n +1) |\  and the second with  $sort -n
	my $data = <<'EOF';
--- Configure.orig
+++ Configure
@@ -14249,7 +14249,7 @@

 set signal
 if eval $compile_ok; then
-	./signal$_exe | $sort -n +1 | $uniq | $awk -f signal.awk >signal.lst
+	./signal$_exe | ($sort -n -k 2 2>/dev/null || $sort -n +1) | $uniq | $awk -f signal.awk >signal.lst
 else
 	echo "(I can't seem be able to compile the whole test program)" >&4
 	echo "(I'll try it in little pieces.)" >&4
@@ -14283,7 +14283,7 @@
 	done
 	if $test -s signal.ls1; then
 		$cat signal.nsg signal.ls1 |
-			$sort -n +1 | $uniq | $awk -f signal.awk >signal.lst
+			$sort -n | $uniq | $awk -f signal.awk >signal.lst
 	fi

 fi
EOF

	# apply it!
	return do_patch( $data );
}

sub patch_hints_netbsd {
#	<Apocalypse> I am having problems compiling perls on NetBSD with -Dusethreads, the error is "pp_sys.c:4804: warning: implicit declaration of function 'getprotobyname_r'",
#		I noticed that 5.10.1 fixed it, so how do I backport it to previous perls so I can build them? Thanks!
#	<apeiron> Do git log -p and look for the commit that fixed it? :)
#	<Apocalypse> Also, I am hitting this problem: http://mail-index.netbsd.org/pkgsrc-users/2008/01/10/msg000117.html
#	<apeiron> (uneducated guess: you're missing a header somewhere)
#	<+dipsy> [ Re: Suspicious errors during build of lang/perl ]
#	<Apocalypse> apeiron: Argh, checking out the git repo would take forever on this slow link :(
#	<apeiron> doh
#	<Apocalypse> I tried the gitweb search thing, but it turned up bazillions of hits and I'm not sure where to begin :(
#	<Apocalypse> I suspect an easy solution would be to copy over the hints/netbsd.sh file but I'm scared of digging that deep :(
#	<@TonyC> the hints file should be safe to copy
#	<mst> Apocalypse: either think. or wait for the slow link to give you bisection.
#	<mst> Apocalypse: there's not many more choices mate :)
#	<Apocalypse> Aha, diff'ing the hints/netbsd.sh file between 5.10.1 and 5.10.0 showed that 5.10.1 added support for netbsd 5.x, yay!
#	<Apocalypse> So, I guess the proper solution would be to copy the hints/netbsd.sh file across to every old perl distro? Will it be sane to do it to say, 5.6.2? :)
#	<@TonyC> maybe :)
#	<Apocalypse> Hmm, trying the compile now with 5.6.2 - if it works then hopefully the rest of 5.8.x would work :)
#	<Apocalypse> I guess I should also apply this strategy to my failing freebsd builds... thanks all!

	# load the hints/netbsd.sh from perl-5.10.1
	my $data = <<'EOP';
# hints/netbsd.sh
#
# Please check with packages@netbsd.org before making modifications
# to this file.

case "$archname" in
'')
    archname=`uname -m`-${osname}
    ;;
esac

# NetBSD keeps dynamic loading dl*() functions in /usr/lib/crt0.o,
# so Configure doesn't find them (unless you abandon the nm scan).
# Also, NetBSD 0.9a was the first release to introduce shared
# libraries.
#
case "$osvers" in
0.9|0.8*)
        usedl="$undef"
        ;;
*)
        case `uname -m` in
        pmax)
                # NetBSD 1.3 and 1.3.1 on pmax shipped an `old' ld.so,
                # which will not work.
                case "$osvers" in
                1.3|1.3.1)
                        d_dlopen=$undef
                        ;;
                esac
                ;;
        esac
        if test -f /usr/libexec/ld.elf_so; then
                # ELF
                d_dlopen=$define
                d_dlerror=$define
                cccdlflags="-DPIC -fPIC $cccdlflags"
                lddlflags="--whole-archive -shared $lddlflags"
                rpathflag="-Wl,-rpath,"
                case "$osvers" in
                1.[0-5]*)
                        #
                        # Include the whole libgcc.a into the perl executable
                        # so that certain symbols needed by loadable modules
                        # built as C++ objects (__eh_alloc, __pure_virtual,
                        # etc.) will always be defined.
                        #
                        ccdlflags="-Wl,-whole-archive -lgcc \
                                -Wl,-no-whole-archive -Wl,-E $ccdlflags"
                        ;;
                *)
                        ccdlflags="-Wl,-E $ccdlflags"
                        ;;
                esac
        elif test -f /usr/libexec/ld.so; then
                # a.out
                d_dlopen=$define
                d_dlerror=$define
                cccdlflags="-DPIC -fPIC $cccdlflags"
                lddlflags="-Bshareable $lddlflags"
                rpathflag="-R"
        else
                d_dlopen=$undef
                rpathflag=
        fi
        ;;
esac

# netbsd had these but they don't really work as advertised, in the
# versions listed below.  if they are defined, then there isn't a
# way to make perl call setuid() or setgid().  if they aren't, then
# ($<, $>) = ($u, $u); will work (same for $(/$)).  this is because
# you can not change the real userid of a process under 4.4BSD.
# netbsd fixed this in 1.3.2.
case "$osvers" in
0.9*|1.[012]*|1.3|1.3.1)
        d_setregid="$undef"
        d_setreuid="$undef"
        ;;
esac
case "$osvers" in
0.9*|1.*|2.*|3.*|4.*|5.*)
        d_getprotoent_r="$undef"
        d_getprotobyname_r="$undef"
        d_getprotobynumber_r="$undef"
        d_setprotoent_r="$undef"
        d_endprotoent_r="$undef"
        d_getservent_r="$undef"
        d_getservbyname_r="$undef"
        d_getservbyport_r="$undef"
        d_setservent_r="$undef"
        d_endservent_r="$undef"
        d_getprotoent_r_proto="0"
        d_getprotobyname_r_proto="0"
        d_getprotobynumber_r_proto="0"
        d_setprotoent_r_proto="0"
        d_endprotoent_r_proto="0"
        d_getservent_r_proto="0"
        d_getservbyname_r_proto="0"
        d_getservbyport_r_proto="0"
        d_setservent_r_proto="0"
        d_endservent_r_proto="0"
        ;;
esac

# These are obsolete in any netbsd.
d_setrgid="$undef"
d_setruid="$undef"

# there's no problem with vfork.
usevfork=true

# This is there but in machine/ieeefp_h.
ieeefp_h="define"

# This script UU/usethreads.cbu will get 'called-back' by Configure
# after it has prompted the user for whether to use threads.
cat > UU/usethreads.cbu <<'EOCBU'
case "$usethreads" in
$define|true|[yY]*)
        lpthread=
        for xxx in pthread; do
                for yyy in $loclibpth $plibpth $glibpth dummy; do
                        zzz=$yyy/lib$xxx.a
                        if test -f "$zzz"; then
                                lpthread=$xxx
                                break;
                        fi
                        zzz=$yyy/lib$xxx.so
                        if test -f "$zzz"; then
                                lpthread=$xxx
                                break;
                        fi
                        zzz=`ls $yyy/lib$xxx.so.* 2>/dev/null`
                        if test "X$zzz" != X; then
                                lpthread=$xxx
                                break;
                        fi
                done
                if test "X$lpthread" != X; then
                        break;
                fi
        done
        if test "X$lpthread" != X; then
                # Add -lpthread.
                libswanted="$libswanted $lpthread"
                # There is no libc_r as of NetBSD 1.5.2, so no c -> c_r.
                # This will be revisited when NetBSD gains a native pthreads
                # implementation.
        else
                echo "$0: No POSIX threads library (-lpthread) found.  " \
                     "You may want to install GNU pth.  Aborting." >&4
                exit 1
        fi
        unset lpthread

        # several reentrant functions are embeded in libc, but haven't
        # been added to the header files yet.  Let's hold off on using
        # them until they are a valid part of the API
        case "$osvers" in
        [012].*|3.[0-1])
                d_getprotobyname_r=$undef
                d_getprotobynumber_r=$undef
                d_getprotoent_r=$undef
                d_getservbyname_r=$undef
                d_getservbyport_r=$undef
                d_getservent_r=$undef
                d_setprotoent_r=$undef
                d_setservent_r=$undef
                d_endprotoent_r=$undef
                d_endservent_r=$undef ;;
        esac
        ;;

esac
EOCBU

# Set sensible defaults for NetBSD: look for local software in
# /usr/pkg (NetBSD Packages Collection) and in /usr/local.
#
loclibpth="/usr/pkg/lib /usr/local/lib"
locincpth="/usr/pkg/include /usr/local/include"
case "$rpathflag" in
'')
        ldflags=
        ;;
*)
        ldflags=
        for yyy in $loclibpth; do
                ldflags="$ldflags $rpathflag$yyy"
        done
        ;;
esac

case `uname -m` in
alpha)
    echo 'int main() {}' > try.c
    gcc=`${cc:-cc} -v -c try.c 2>&1|grep 'gcc version egcs-2'`
    case "$gcc" in
    '' | "gcc version egcs-2.95."[3-9]*) ;; # 2.95.3 or better okay
    *)  cat >&4 <<EOF
***
*** Your gcc ($gcc) is known to be
*** too buggy on netbsd/alpha to compile Perl with optimization.
*** It is suggested you install the lang/gcc package which should
*** have at least gcc 2.95.3 which should work okay: use for example
*** Configure -Dcc=/usr/pkg/gcc-2.95.3/bin/cc.  You could also
*** Configure -Doptimize=-O0 to compile Perl without any optimization
*** but that is not recommended.
***
EOF
        exit 1
        ;;
    esac
    rm -f try.*
    ;;
esac

# NetBSD/sparc 1.5.3/1.6.1 dumps core in the semid_ds test of Configure.
case `uname -m` in
sparc) d_semctl_semid_ds=undef ;;
esac

EOP

	# we don't use do_patch() because it isn't a patch...
	do_replacefile( "$PATH/build/perl-$perlver-$perlopts/hints/netbsd.sh", $data );

	return;
}

sub patch_hints_freebsd {
	# same strategy as netbsd, we need it...

	# load the hints/netbsd.sh from perl-5.10.1
	my $data = <<'EOP';
# Original based on info from
# Carl M. Fongheiser <cmf@ins.infonet.net>
# Date: Thu, 28 Jul 1994 19:17:05 -0500 (CDT)
#
# Additional 1.1.5 defines from
# Ollivier Robert <Ollivier.Robert@keltia.frmug.fr.net>
# Date: Wed, 28 Sep 1994 00:37:46 +0100 (MET)
#
# Additional 2.* defines from
# Ollivier Robert <Ollivier.Robert@keltia.frmug.fr.net>
# Date: Sat, 8 Apr 1995 20:53:41 +0200 (MET DST)
#
# Additional 2.0.5 and 2.1 defined from
# Ollivier Robert <Ollivier.Robert@keltia.frmug.fr.net>
# Date: Fri, 12 May 1995 14:30:38 +0200 (MET DST)
#
# Additional 2.2 defines from
# Mark Murray <mark@grondar.za>
# Date: Wed, 6 Nov 1996 09:44:58 +0200 (MET)
#
# Modified to ensure we replace -lc with -lc_r, and
# to put in place-holders for various specific hints.
# Andy Dougherty <doughera@lafayette.edu>
# Date: Tue Mar 10 16:07:00 EST 1998
#
# Support for FreeBSD/ELF
# Ollivier Robert <roberto@keltia.freenix.fr>
# Date: Wed Sep  2 16:22:12 CEST 1998
#
# The two flags "-fpic -DPIC" are used to indicate a
# will-be-shared object.  Configure will guess the -fpic, (and the
# -DPIC is not used by perl proper) but the full define is included to
# be consistent with the FreeBSD general shared libs building process.
#
# setreuid and friends are inherently broken in all versions of FreeBSD
# before 2.1-current (before approx date 4/15/95). It is fixed in 2.0.5
# and what-will-be-2.1
#

case "$osvers" in
0.*|1.0*)
	usedl="$undef"
	;;
1.1*)
	malloctype='void *'
	groupstype='int'
	d_setregid='undef'
	d_setreuid='undef'
	d_setrgid='undef'
	d_setruid='undef'
	;;
2.0-release*)
	d_setregid='undef'
	d_setreuid='undef'
	d_setrgid='undef'
	d_setruid='undef'
	;;
#
# Trying to cover 2.0.5, 2.1-current and future 2.1/2.2
# It does not covert all 2.1-current versions as the output of uname
# changed a few times.
#
# Even though seteuid/setegid are available, they've been turned off
# because perl isn't coded with saved set[ug]id variables in mind.
# In addition, a small patch is requried to suidperl to avoid a security
# problem with FreeBSD.
#
2.0.5*|2.0-built*|2.1*)
 	usevfork='true'
	case "$usemymalloc" in
	    "") usemymalloc='n'
	        ;;
	esac
	d_setregid='define'
	d_setreuid='define'
	d_setegid='undef'
	d_seteuid='undef'
	test -r ./broken-db.msg && . ./broken-db.msg
	;;
#
# 2.2 and above have phkmalloc(3).
# don't use -lmalloc (maybe there's an old one from 1.1.5.1 floating around)
2.2*)
 	usevfork='true'
	case "$usemymalloc" in
	    "") usemymalloc='n'
	        ;;
	esac
	libswanted=`echo $libswanted | sed 's/ malloc / /'`
	libswanted=`echo $libswanted | sed 's/ bind / /'`
	# iconv gone in Perl 5.8.1, but if someone compiles 5.8.0 or earlier.
	libswanted=`echo $libswanted | sed 's/ iconv / /'`
	d_setregid='define'
	d_setreuid='define'
	d_setegid='define'
	d_seteuid='define'
	# d_dosuid='define' # Obsolete.
	;;
*)	usevfork='true'
	case "$usemymalloc" in
	    "") usemymalloc='n'
	        ;;
	esac
	libswanted=`echo $libswanted | sed 's/ malloc / /'`
	;;
esac

# Dynamic Loading flags have not changed much, so they are separated
# out here to avoid duplicating them everywhere.
case "$osvers" in
0.*|1.0*) ;;

1*|2*)	cccdlflags='-DPIC -fpic'
	lddlflags="-Bshareable $lddlflags"
	;;

*)
        objformat=`/usr/bin/objformat`
        if [ x$objformat = xaout ]; then
            if [ -e /usr/lib/aout ]; then
                libpth="/usr/lib/aout /usr/local/lib /usr/lib"
                glibpth="/usr/lib/aout /usr/local/lib /usr/lib"
            fi
            lddlflags='-Bshareable'
        else
            libpth="/usr/lib /usr/local/lib"
            glibpth="/usr/lib /usr/local/lib"
            ldflags="-Wl,-E "
            lddlflags="-shared "
        fi
        cccdlflags='-DPIC -fPIC'
        ;;
esac

case "$osvers" in
0*|1*|2*|3*) ;;

*)
	ccflags="${ccflags} -DHAS_FPSETMASK -DHAS_FLOATINGPOINT_H"
	if /usr/bin/file -L /usr/lib/libc.so | /usr/bin/grep -vq "not stripped" ; then
	    usenm=false
	fi
        ;;
esac

cat <<'EOM' >&4

Some users have reported that Configure halts when testing for
the O_NONBLOCK symbol with a syntax error.  This is apparently a
sh error.  Rerunning Configure with ksh apparently fixes the
problem.  Try
	ksh Configure [your options]

EOM

# From: Anton Berezin <tobez@plab.ku.dk>
# To: perl5-porters@perl.org
# Subject: [PATCH 5.005_54] Configure - hints/freebsd.sh signal handler type
# Date: 30 Nov 1998 19:46:24 +0100
# Message-ID: <864srhhvcv.fsf@lion.plab.ku.dk>

signal_t='void'
d_voidsig='define'

# set libperl.so.X.X for 2.2.X
case "$osvers" in
2.2*)
    # unfortunately this code gets executed before
    # the equivalent in the main Configure so we copy a little
    # from Configure XXX Configure should be fixed.
    if $test -r $src/patchlevel.h;then
       patchlevel=`awk '/define[ 	]+PERL_VERSION/ {print $3}' $src/patchlevel.h`
       subversion=`awk '/define[ 	]+PERL_SUBVERSION/ {print $3}' $src/patchlevel.h`
    else
       patchlevel=0
       subversion=0
    fi
    libperl="libperl.so.$patchlevel.$subversion"
    unset patchlevel
    unset subversion
    ;;
esac

# This script UU/usethreads.cbu will get 'called-back' by Configure
# after it has prompted the user for whether to use threads.
cat > UU/usethreads.cbu <<'EOCBU'
case "$usethreads" in
$define|true|[yY]*)
        lc_r=`/sbin/ldconfig -r|grep ':-lc_r'|awk '{print $NF}'|sed -n '$p'`
        case "$osvers" in
	0*|1*|2.0*|2.1*)   cat <<EOM >&4
I did not know that FreeBSD $osvers supports POSIX threads.

Feel free to tell perlbug@perl.org otherwise.
EOM
	      exit 1
	      ;;

        2.2.[0-7]*)
              cat <<EOM >&4
POSIX threads are not supported well by FreeBSD $osvers.

Please consider upgrading to at least FreeBSD 2.2.8,
or preferably to the most recent -RELEASE or -STABLE
version (see http://www.freebsd.org/releases/).

(While 2.2.7 does have pthreads, it has some problems
 with the combination of threads and pipes and therefore
 many Perl tests will either hang or fail.)
EOM
	      exit 1
	      ;;

	[3-5].*)
	      if [ ! -r "$lc_r" ]; then
	      cat <<EOM >&4
POSIX threads should be supported by FreeBSD $osvers --
but your system is missing the shared libc_r.
(/sbin/ldconfig -r doesn't find any).

Consider using the latest STABLE release.
EOM
		 exit 1
	      fi
	      # 500016 is the first osreldate in which one could
	      # just link against libc_r without disposing of libc
	      # at the same time.  500016 ... up to whatever it was
	      # on the 31st of August 2003 can still be used with -pthread,
	      # but it is not necessary.

	      # Anton Berezin says that post 500something we're wrong to be
	      # to be using -lc_r, and should just be using -pthread on the
	      # linker line.
	      # So presumably really we should be checking that $osver is 5.*)
	      # and that `/sbin/sysctl -n kern.osreldate` -ge 500016
	      # or -lt 500something and only in that range not doing this:
	      ldflags="-pthread $ldflags"

	      # Both in 4.x and 5.x gethostbyaddr_r exists but
	      # it is "Temporary function, not threadsafe"...
	      # Presumably earlier it didn't even exist.
	      d_gethostbyaddr_r="undef"
	      d_gethostbyaddr_r_proto="0"
	      ;;

	*)
	      # 7.x doesn't install libc_r by default, and Configure
	      # would fail in the code following
	      #
	      # gethostbyaddr_r() appears to have been implemented in 6.x+
	      ldflags="-pthread $ldflags"
	      ;;

	esac

        case "$osvers" in
        [1-4]*)
	    set `echo X "$libswanted "| sed -e 's/ c / c_r /'`
	    shift
	    libswanted="$*"
	    ;;
        *)
	    set `echo X "$libswanted "| sed -e 's/ c //'`
	    shift
	    libswanted="$*"
	    ;;
	esac

	# Configure will probably pick the wrong libc to use for nm scan.
	# The safest quick-fix is just to not use nm at all...
	usenm=false

        case "$osvers" in
        2.2.8*)
            # ... but this does not apply for 2.2.8 - we know it's safe
            libc="$lc_r"
            usenm=true
           ;;
        esac

        unset lc_r

	# Even with the malloc mutexes the Perl malloc does not
	# seem to be threadsafe in FreeBSD?
	case "$usemymalloc" in
	'') usemymalloc=n ;;
	esac
esac
EOCBU

# malloc wrap works
case "$usemallocwrap" in
'') usemallocwrap='define' ;;
esac

# XXX Under FreeBSD 6.0 (and probably most other similar versions)
# Perl_die(NULL) generates a warning:
#    pp_sys.c:491: warning: null format string
# Configure supposedely tests for this, but apparently the test doesn't
# work.  Volunteers with FreeBSD are needed to improving the Configure test.
# Meanwhile, the following workaround should be safe on all versions
# of FreeBSD.
d_printf_format_null='undef'
EOP

	do_replacefile( "$PATH/build/perl-$perlver-$perlopts/hints/freebsd.sh", $data );

	return;
}

sub do_replacefile {
	my( $file, $data ) = @_;
	do_log( "[PERLBUILDER] Replacing file '$file' with new data" );

	# for starters, we delete the file
	unlink( $file ) or die "Unable to unlink $file: $!";
	open( my $f, '>', $file ) or die "Unable to open $file for writing: $!";
	print $f $data;
	close( $f ) or die "Unable to close $file: $!";

	return;
}
