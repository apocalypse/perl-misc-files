#!/usr/bin/env perl
use strict; use warnings;

# We have successfully compiled those perl versions:
# 5.6.1, 5.6.2
# 5.8.1, 5.8.2, 5.8.3, 5.8.4, 5.8.5, 5.8.6, 5.8.7, 5.8.8, 5.8.9
# 5.10.0, 5.10.1
# 5.11.0, 5.11.1, 5.11.2, 5.11.3, 5.11.4, 5.11.5
# 5.12.0

# We skip 5.6.0 and 5.8.0 because they are problematic builds

# The MSWin32 code in here cheats - it doesn't actually "compile" perl, it just
# uses Strawberries and bootstraps everything from there...

# We have successfully compiled perl on those OSes:
# x86_64/x64/amd64 (64bit) OSes:
#	OpenSolaris 2009.6, FreeBSD 5.2-RELEASE, Ubuntu-server 9.10, NetBSD 5.0.1
# x86 (32bit) OSes:
#

# This compiler builds each perl with a matrix of 49 possible combinations.
# The options are: threads multiplicity longdouble mymalloc 32/64bitness
# Compiling the entire perl suite listed above will result in: 931 perls!
# Each perl averages 40M with all the necessary modules to smoke CPAN preinstalled. ( ~37GB total! )

# this script does everything, but we need some layout to be specified!
# /home/cpan					<-- the main directory
# /home/cpan/tmp				<-- tmp directory for cpan/perl/etc cruft
# /home/cpan/CPANPLUS-0.XX			<-- the extracted CPANPLUS directory we use
# /home/cpan/build				<-- where we store our perl builds + tarballs
# /home/cpan/build/perl-5.6.2.tar.gz		<-- one perl tarball
# /home/cpan/build/perl_5.6.2_thr-32		<-- one extracted perl build
# /home/cpan/perls				<-- the perl installation directory
# /home/cpan/perls/perl_5.6.2_thr-32		<-- finalized perl install
# /home/cpan/cpanp_conf				<-- where we store the CPANPLUS configs
# /home/cpan/cpanp_conf/perl_5.6.2_thr-32	<-- CPANPLUS config location for a specific perl
# /home/cpan/compile_perl.pl			<-- where this script should be

# this script does everything, but we need some layout to be specified ( this is the win32 variant )
# You need to install bootstrap perl first!
# c:\cpansmoke							<-- the main directory
# c:\cpansmoke\tmp						<-- tmp directory for cpan/perl/etc cruft
# c:\cpansmoke\build						<-- where we store our perl builds + zips
# c:\cpansmoke\build\strawberry-perl-5.8.9.3.zip		<-- one perl zip
# c:\cpansmoke\perls						<-- the perl installation directory
# c:\cpansmoke\perls\strawberry_perl_5.8.9.3_default		<-- finalized perl install
# c:\cpansmoke\cpanp_conf					<-- where we store the CPANPLUS configs
# c:\cpansmoke\cpanp_conf\strawberry_perl_5.8.9.3_default	<-- CPANPLUS config location for a specific perl
# c:\cpansmoke\compile_perl.pl					<-- where this script should be

# TODO LIST
#	- fix all TODO lines in this code :)
#	- we should run 3 CPANPLUS configs per perl - "prefer_makefile" = true + false + autodetect
#	- put all our module prereqs into a BEGIN { eval } check so we can pretty-print the missing modules
#	- Use ActiveState perl?
#		- use their binary builds + source build?
#	- Some areas of the code print "\n" but maybe we need a portable way for that? use $/ ?
#	- What is "pager" really for in CPANPLUS config? Can we undef it?
#	- on some systems with the possibility of different compilers, can we use them all?
#		- i.e. OpenSolaris - Sun's cc and gcc?
#		- <@TonyC> http://software.intel.com/en-us/articles/non-commercial-software-development/ # free icc for linux!
#		- <@TonyC> opencc: http://developer.amd.com/cpu/open64/Pages/default.aspx # free amd 64bit compiler
#		- <TonyC> Apocalypse: http://www.thefreecountry.com/compilers/cpp.shtml # a nice page with lots of compilers
#	- <@rafl> i wonder if running a smoker with parallel testing would be useful
#		- <@Tux> I'm wondering how big a percentage of CPAN actually fails under prove --shuffle -j4
#		- we need to do that kind of insanity!
#	- figure out a way to have VMs running with no internet access
#		- one VM with inet, another VM without
#		- that way, we can stab authors who blindly assume the inet is available :)
#	- look at BinGOs' excellent work in CPAN smoking
#		- http://github.com/bingos/cpan-smoke-tools
#		- App::Smokebrew
#	- change the logger from "[FOOBAR] msg" to "<<FOOBAR>> msg" so it's easier to differentiate it vs CPANPLUS output?
#	- investigate http://www.citrusperl.org/ as an extra perl for win32?
#	- use "make test_harness" for parallel testing and set $ENV{TEST_JOBS} and "make -jN" to the same number
#	- use this? http://yellow-perl.berlios.de/
#	- http://win32.perl.org/wiki/index.php?title=Win32_Distributions # for more win32 dists :)
#	- does -des already do that?
#		<@theory> What's the configure option to prevent the @INC paths of alread-installed Perls from being included in @INC?
#		<b_jonas> theory: look at INSTALL, it tells about that
#		<b_jonas> theory: -Dinc_version_list=none
#		<@theory> b_jonas: Right-o, thanks.
#	- look into porting/maintainers.t fail because of aggressive patching?

# load our dependencies
use Capture::Tiny qw( tee_merged );
use Prompt::Timeout qw( prompt );
use Sort::Versions qw( versioncmp );
use Sys::Hostname qw( hostname );
use File::Spec;
use File::Path::Tiny;
use File::Which qw( which );
use Shell::Command qw( mv );
use File::Find::Rule;
use CPAN::Perl::Releases qw( perl_tarballs perl_versions );
use Devel::PatchPerl;
use Sys::Info;

# Global config hash
my %C = (
	'matrix'			=> 1,			# compile the matrix of perl options or not?
	'devel'			=> 0,			# compile the devel versions of perl?
	'home'			=> $ENV{HOME},		# the home path where we do our stuff ( also used for local CPANPLUS config! )
	'server'			=> 'smoker-master',	# our local CPAN server ( used for mirror/cpantesters upload/etc )
	's_ct_port'		=> '11111',		# our local CT2.0 socket/httpgateway port
	's_cpanidx_port'	=> '11110',		# our local CPANIDX port
	's_cpanidx_path'	=> '/CPANIDX/',		# our local CPANIDX path
	's_ftpdir'			=> '/CPAN/',		# our local CPAN mirror ftp dir
	'email'			=> 'apocal@cpan.org',	# the email address to use for CPANPLUS config
);
if ( $^O eq 'MSWin32' ) {
	$C{home} = "C:\\cpansmoke";
}

# Holds our cached logs
my @LOGS = ();

# Internal variables for bookkeeping
my %stuff = (
	'cpanp_ver'	=> undef,		# the CPANPLUS version we'll use for cpanp-boxed
	'perlver'	=> undef,		# the perl version we're processing now
	'perlopts'	=> undef,		# the perl options we're using for this run
	'perldist'	=> undef,		# the full perl dist ( perl_5.6.2_default or perl_$perlver_$perlopts )
);

# Do some basic sanity checks
do_sanity_checks();

# What option do we want to do?
prompt_action();

# all done!
exit;

sub do_error {
	my $cat = shift;
	my $line = shift;

	do_log( $cat, $line );
	die 'ERROR';
}

sub do_sanity_checks {
	my $res;

	if ( $< == 0 ) {
		do_log( 'SANITYCHECK', "You are running this as root! Be careful in what you do!" );
		$res = lc( do_prompt( "Are you really sure you want to run this?", 'n' ) );
		if ( $res eq 'n' ) {
			exit;
		}
	}

	# Move to our path!
	chdir( $C{home} ) or do_error( 'SANITYCHECK', "Unable to chdir($C{home})" );

	# First of all, we check to see if our "essential" binaries are present
	my @binaries = qw( perl cpanp lwp-mirror lwp-request );
	if ( $^O eq 'MSWin32' ) {
		push( @binaries, qw( cacls more cmd dmake ) );
	} else {
		push( @binaries, qw( sudo chown make sh patch ) );
	}

	foreach my $bin ( @binaries ) {
		my $error = 0;
		if ( ! length get_binary_path( $bin ) ) {
			do_log( 'SANITYCHECK', "The binary '$bin' was not found!" );
			$error++;
		}
		if ( $error ) {
			do_error( 'SANITYCHECK', 'Essential binaries are missing...' );
		}
	}

	# Sanity check strawberry on win32
	if ( $^O eq 'MSWin32' ) {
		if ( $ENV{PATH} =~ /strawberry/ ) {
			do_error( 'SANITYCHECK', "Detected Strawberry Perl in $ENV{PATH}, please fix it!" );
		}
		if ( -d "C:\\strawberry" ) {
			do_error( 'SANITYCHECK', "Detected Old Strawberry Perl in C:\\strawberry, please fix it!" );
		}
	}

	# Create some directories we need
	foreach my $dir ( qw( build tmp perls cpanp_conf ) ) {
		my $localdir = File::Spec->catdir( $C{home}, $dir );
		if ( ! -d $localdir ) {
			$res = lc( do_prompt( "Do you want us to auto-create the build dirs?", 'y' ) );
			if ( $res eq 'y' ) {
				do_mkdir( $localdir );
			}
		}
	}

	# blow away any annoying .cpan directories that remain
	my $cpan;
	if ( $^O eq 'MSWin32' ) {
		# TODO is it always in this path?
		# commit: wrote 'C:\Documents and Settings\cpan\Local Settings\Application Data\.cpan\CPAN\MyConfig.pm'
		$cpan = 'C:\\Documents and Settings\\' . $ENV{USERNAME} . '\\Local Settings\\Application Data\\.cpan';
	} else {
		$cpan = File::Spec->catdir( $C{home}, '.cpan' );
	}

	if ( -d $cpan && (stat(_))[4] != 0 ) {
		$res = lc( do_prompt( "Do you want us to purge/fix the CPAN config dir?", 'n' ) );
		if ( $res eq 'y' ) {
			do_rmdir( $cpan );

			# thanks to BinGOs for the idea to prevent rogue module installs via CPAN
			do_mkdir( $cpan );
			if ( $^O eq 'MSWin32' ) {
				# TODO use cacls.exe or something?
			} else {
				do_shellcommand( "sudo chown root $cpan" );
			}
		}
	}

	return 1;
}

sub do_prompt {
	my ( $str, $default ) = @_;
	my $res = prompt( $str, $default, 120 );

	# Print a newline so we have a nice console
	print "\n\n";

	# We don't like handling undefined values...
	if ( ! defined $res ) {
		return '';
	} else {
		return $res;
	}
}


sub prompt_action {
	my $res;
	while ( ! defined $res ) {
		print "\n";
		$res = lc( do_prompt( "What action do you want to do today? [(b)uild/use (d)evel perl/(e)xit/(i)nstall/too(l)chain update/perl(m)atrix/unchow(n)/(p)rint ready perls/(r)econfig cpanp/(s)ystem toolchain update/(u)ninstall/cho(w)n]", 'e' ) );
		print "\n";
		if ( $res eq 'b' ) {
			# get list of perls that is known
			my @perls_list;
			if ( $^O eq 'MSWin32' ) {
				# we use strawberries!
				my $output = do_shellcommand( "lwp-request ftp://$C{server}/STRAWBERRY_PERL" );
				foreach my $l ( @$output ) {
					if ( $l =~ /^\-.+\s+strawberry\-perl\-([^\s]+)\.zip$/ ) {
						push( @perls_list, $1 );
					}
				}
			} else {
				@perls_list = perl_versions();
				@perls_list = grep { $_ !~ /(?:RC|TRIAL|_|5\.004|5\.005)/ } @perls_list;
				if ( ! $C{devel} ) {
					@perls_list = grep { $_ !~ /\.\d?[13579]\./ } @perls_list;
				}
			}

			# prompt user for perl version to compile
			$res = prompt_select_perlver( \@perls_list );
			if ( defined $res ) {
				# Loop through all versions, starting from newest to oldest
				foreach my $p ( reverse @$res ) {
					install_perl( $p );
				}
			}
		} elsif ( $res eq 'p' ) {
			# Print out ready perls
			my $perls = getReadyPerls();
			foreach my $p ( @$perls ) {
				print "\t$p\n";
			}
		} elsif ( $res eq 's' ) {
			# configure the system for smoking!
			do_config_systemCPANPLUS();
		} elsif ( $res eq 'd' ) {
			# should we use the perl devel versions?
			print "Current devel perl status: " . ( $C{devel} ? 'Y' : 'N' ) . "\n";
			$res = lc( do_prompt( "Compile/use the devel perls?", 'n' ) );
			if ( $res eq 'y' ) {
				$C{devel} = 1;
			} else {
				$C{devel} = 0;
			}
		} elsif ( $res eq 'l' ) {
			# Update the entire toolchain + Metabase deps
			do_log( 'CPAN', "Executing toolchain update on perls..." );
			iterate_perls( sub {
				if ( do_cpanp_action( $stuff{perldist}, "s selfupdate all" ) ) {
					do_log( 'CPAN', "Successfully updated CPANPLUS on '$stuff{perldist}'" );

					# Get our toolchain modules
					my $cpanp_action = 'i ' . join( ' ', @{ get_CPANPLUS_toolchain() } );
					if ( do_cpanp_action( $stuff{perldist}, $cpanp_action ) ) {
						do_log( 'CPAN', "Successfully updated toolchain modules on '$stuff{perldist}'" );
					} else {
						do_log( 'CPAN', "Failed to update toolchain modules on '$stuff{perldist}'" );
					}
				} else {
					do_log( 'CPAN', "Failed to update CPANPLUS on '$stuff{perldist}'" );
				}
			} );
		} elsif ( $res eq 'm' ) {
			# Should we compile/configure/use/etc the perlmatrix?
			print "Current matrix perl status: " . ( $C{matrix} ? 'Y' : 'N' ) . "\n";
			$res = lc( do_prompt( "Compile/use the perl matrix?", 'n' ) );
			if ( $res eq 'y' ) {
				$C{matrix} = 1;
			} else {
				$C{matrix} = 0;
			}
		} elsif ( $res eq 'i' ) {
			# install a specific module
			my $module = do_prompt( "What module(s) should we install?", '' );
			if ( length $module ) {
				do_log( 'CPAN', "Installing '$module' on perls..." );
				iterate_perls( sub {
					if ( do_cpanp_action( $stuff{perldist}, "i $module" ) ) {
						do_log( 'CPAN', "Installed the module on '$stuff{perldist}'" );
					} else {
						do_log( 'CPAN', "Failed to install the module on '$stuff{perldist}'" );
					}
				} );
			} else {
				print "Module name not specified, please try again.\n";
			}
		} elsif ( $res eq 'u' ) {
			# uninstall a specific module
			my $module = do_prompt( "What module should we uninstall?", '' );
			if ( length $module ) {
				do_log( 'CPAN', "Uninstalling '$module' on perls..." );
				iterate_perls( sub {
					# use --force so we skip the prompt
					if ( do_cpanp_action( $stuff{perldist}, "u $module --force" ) ) {
						do_log( 'CPAN', "Uninstalled the module from '$stuff{perldist}'" );
					} else {
						do_log( 'CPAN', "Failed to uninstall the module from '$stuff{perldist}'" );
					}
				} );
			} else {
				print "Module name not specified, please try again.\n";
			}
		} elsif ( $res eq 'e' ) {
			return;
		} elsif ( $res eq 'w' ) {
			if ( $^O eq 'MSWin32' ) {
				# TODO use cacls.exe or something else?
				do_log( 'UTILS', "Unable to chown on $^O" );
			} else {
				# thanks to BinGOs for the idea to chown the perl installs to prevent rogue modules!
				do_log( 'UTILS', "Executing chown -R root on perl installs..." );
				iterate_perls( sub {
					# some OSes don't have root as a group, so we just set the user
					do_shellcommand( "sudo chown -R root " . File::Spec->catdir( $C{home}, 'perls', $stuff{perldist} ) );
				} );
			}
		} elsif ( $res eq 'n' ) {
			if ( $^O eq 'MSWin32' ) {
				# TODO use cacls.exe or something else?
				do_log( 'UTILS', "Unable to chown on $^O" );
			} else {
				# Unchown the perl installs so we can do stuff to them :)
				do_log( 'UTILS', "Executing chown -R $< on perl installs..." );
				iterate_perls( sub {
					do_shellcommand( "sudo chown -R $< " . File::Spec->catdir( $C{home}, 'perls', $stuff{perldist} ) );
				} );
			}
		} elsif ( $res eq 'r' ) {
			# reconfig all perls' CPANPLUS settings
			do_log( 'CPANPLUS', "Reconfiguring CPANPLUS settings on perls..." );
			iterate_perls( sub {
				do_installCPANPLUS_config();
			} );
		} else {
			print "Unknown action, please try again.\n";
		}

		# allow the user to run another loop
		$res = undef;
		$stuff{perlver} = $stuff{perlopts} = $stuff{perldist} = undef;
		reset_logs();
	}

	return;
}

sub do_config_systemCPANPLUS {
	# First of all, we need to be root!
	if ( $< != 0 ) {
		# Make sure the user knows what they are doing!
		my $res = lc( do_prompt( "You are not running as root, execute this action?", "n" ) );
		if ( $res ne 'y' ) {
			do_log( 'CPANPLUS', 'Refusing to configure system CPANPLUS without approval...' );
			return 0;
		}
	}

# We let CPANPLUS automatically figure it out!
#	$conf->set_conf( prefer_makefile => 1 );

# We don't let the system perl use CPANIDX as a nice "differentiator" and as a way for it to remain as close to "default" as possible...

	# configure the system Config settings
	my $uconfig = <<'END';
###############################################
###
###  Configuration for CPANPLUS::Config::User
###
###############################################

# Last changed: XXXTIMEXXX

=pod

=head1 NAME

CPANPLUS::Config::User

=head1 DESCRIPTION

This is a CPANPLUS configuration file.

=cut

package CPANPLUS::Config::User;

use strict;

sub setup {
	my $conf = shift;

	$conf->set_conf( allow_build_interactivity => 0 );
	$conf->set_conf( base => 'XXXCATDIR-XXXPATHXXX/.cpanplusXXX' );
	$conf->set_conf( buildflags => 'XXXBUILDFLAGSXXX' );
	$conf->set_conf( cpantest => 0 );
	$conf->set_conf( cpantest_mx => '' );
	$conf->set_conf( debug => 1 );
	$conf->set_conf( dist_type => '' );
	$conf->set_conf( email => 'XXXCONFIG-EMAILXXX' );
	$conf->set_conf( enable_custom_sources => 0 );
	$conf->set_conf( extractdir => '' );
	$conf->set_conf( fetchdir => '' );
	$conf->set_conf( flush => 1 );
	$conf->set_conf( force => 0 );
	$conf->set_conf( hosts => [
		{
			'path' => 'XXXCONFIG-S_FTPDIRXXX',
			'scheme' => 'ftp',
			'host' => 'XXXCONFIG-SERVERXXX',
		},
	] );
	$conf->set_conf( lib => [] );
	$conf->set_conf( makeflags => 'XXXMAKEFLAGSXXX' );
	$conf->set_conf( makemakerflags => '' );
	$conf->set_conf( md5 => 1 );
	$conf->set_conf( no_update => 1 );
	$conf->set_conf( passive => 1 );
	$conf->set_conf( prefer_bin => XXXPREFERBINXXX );
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

	$conf->set_program( editor => undef );
	$conf->set_program( make => 'XXXWHICH-makeXXX' );
	$conf->set_program( pager => 'XXXWHICH-lessXXX' );
	$conf->set_program( perlwrapper => 'XXXWHICH-cpanp-run-perlXXX' );
	$conf->set_program( shell => 'XXXWHICH-bashXXX' );
	$conf->set_program( sudo => undef );

	return 1;
}
1;
END

	# actually config CPANPLUS!
	do_config_CPANPLUS_cfg( $uconfig );

	# update the indexes
	if ( ! do_cpanp_action( undef, 'x --update_source' ) ) {
		return 0;
	}

	# Now, get it to update everything
	if ( ! do_cpanp_action( undef, 's selfupdate all' ) ) {
		return 0;
	}

	# Okay, now the rest of the toolchain...
	my $cpanp_action = 'i ' . join( ' ', @{ get_CPANPLUS_toolchain() } );
	if ( ! do_cpanp_action( undef, $cpanp_action ) ) {
		return 0;
	}

	return 1;
}

sub split_perl {
	my $perl = shift;

	# $perl should be something like "perl_5.6.2_default"
	if ( $perl =~ /^perl\_(.+)\_(.+)$/ ) {
		return( $1, $2 );
	} else {
		return;
	}
}

sub do_mv {
	my( $src, $dst, $quiet ) = @_;

	do_log( 'MV', "Executing mv( $src => $dst )" ) if ! $quiet;

	mv( $src, $dst ) or do_error( 'MV', "Unable to mv '$src => $dst': $!" );

	return;
}

sub iterate_perls {
	my $sub = shift;

	# prompt user for perl version to iterate on
	my $res = prompt_select_perlver( getReadyPerls() );
	if ( ! defined $res ) {
		print "No perls specified, aborting!\n";
		return;
	}

	# Get all available perls and iterate over them
	if ( $^O eq 'MSWin32' ) {
		# alternate method, we have to swap perls...
		local $ENV{PATH} = cleanse_strawberry_path();

		foreach my $p ( reverse @$res ) {
			do_log( 'ITERATOR', "Iterating over $p" );

			# move this perl to c:\strawberry
			if ( -d "C:\\strawberry" ) {
				do_error( 'ITERATOR', 'Old strawberry perl found in C:\\strawberry, please fix it!' );
			}
			my $perlpath = File::Spec->catdir( $C{home}, 'perls', $p );
			do_mv( $perlpath, "C:\\strawberry" );

			# Okay, set the 3 perl variables we need
			( $stuff{perlver}, $stuff{perlopts} ) = split_perl( $p );
			$stuff{perldist} = $p;

			# execute action
			$sub->();

			# move this perl back to original place
			do_mv( "C:\\strawberry", $perlpath );
		}
	} else {
		# Loop through all versions, starting from newest to oldest
		foreach my $p ( reverse @$res ) {
			do_log( 'ITERATOR', "Iterating over $p" );

			# Okay, set the 3 perl variables we need
			( $stuff{perlver}, $stuff{perlopts} ) = split_perl( $p );
			$stuff{perldist} = $p;

			$sub->();
		}
	}

	return;
}

# finds all installed perls that have smoke.ready file in them
sub getReadyPerls {
	my $path = File::Spec->catdir( $C{home}, 'perls' );
	if ( -d $path ) {
		opendir( PERLS, $path ) or do_error( 'UTILS', "Unable to opendir ($path): $!" );
		my @list = readdir( PERLS );
		closedir( PERLS ) or do_error( 'UTILS', "Unable to closedir ($path): $!" );

		# find the ready ones
		my %ready = ();
		foreach my $p ( @list ) {
			if ( $p =~ /^\S\_/ and -d File::Spec->catdir( $path, $p ) and -e File::Spec->catfile( $path, $p, 'ready.smoke' ) ) {
				# rip out the version
				if ( $p =~ /perl\_([\d\.\w\-]+)\_/ ) {
					push( @{ $ready{ $1 } }, $p );
				} elsif ( $p =~ /^strawberry_(.+)$/ ) {
					push( @{ $ready{ $1 } }, $p );
				}
			}
		}

		# crap, but I want the list sorted for aesthetics :)
		my @ready;
		foreach my $p ( sort versioncmp keys %ready ) {
			foreach my $perl ( sort {$a cmp $b} @{ $ready{ $p } } ) {
				push( @ready, $perl );
			}
		}

		print "Ready Perls: " . scalar @ready . "\n";
		return \@ready;
	} else {
		return [];
	}
}

sub reset_logs {
	@LOGS = ();
	return;
}

sub save_logs {
	my $end = shift;

	# Dump the logs into the file
	my $file = File::Spec->catfile( $C{home}, 'perls', $stuff{perldist} . ".$end" );
	do_replacefile( $file, join( "\n", @LOGS ), 1 );

	return;
}

sub do_log {
	my $cat = shift;
	my $line = shift;

	# Did we get a category?
	if ( ! defined $line ) {
		print $cat . "\n";
		push( @LOGS, $cat );
	} else {
		# set a fancy "output"
		my $str ='<<' . localtime . '-' . $cat . '>> ' . $line;
		print $str . "\n";
		push( @LOGS, $str );
	}

	return;
}

sub do_config_CPANPLUS_cfg {
	my $uconfig = shift;
	do_log( 'CPANPLUS', "Configuring the CPANPLUS config..." );

	# blow away the old cpanplus dir if it's there
	my $cpanplus = File::Spec->catdir( $C{home}, '.cpanplus' );
	if ( -d $cpanplus ) {
		do_rmdir( $cpanplus );
	}

	# transform the XXXargsXXX
	$uconfig = do_replacements( $uconfig );

	# save it!
	my $path = File::Spec->catdir( $cpanplus, 'lib', 'CPANPLUS', 'Config' );
	do_mkdir( $path );
	do_replacefile( File::Spec->catfile( $path, 'User.pm' ), $uconfig );

	return 1;
}

# prompt the user for perl version
# TODO allow the user to make multiple choices? (m)ultiple option?
sub prompt_select_perlver {
	my $perls = shift;

	if ( ! defined $perls or scalar @$perls == 0 ) {
		return undef;
	}

	my $res;
	while ( ! defined $res ) {
		$res = do_prompt( "Which perl version to use? [ver/(d)isplay/(a)ll/(e)xit]", $perls->[-1] );
		if ( lc( $res ) eq 'd' ) {
			# display available versions
			print "Perl versions (" . scalar @$perls . "): " . join( ' ', @$perls ) . "\n";
		} elsif ( lc( $res ) eq 'a' ) {
			return $perls;
		} elsif ( lc( $res ) eq 'e' ) {
			return undef;
		} else {
			# make sure the version exists
			if ( ! grep { $_ eq $res } @$perls ) {
				print "The selected version doesn't exist, please try again.";
			} else {
				return [ $res ];
			}
		}

		$res = undef;
	}

	return undef;
}

sub install_perl {
	my $perl = shift;

	reset_logs();

	if ( $^O eq 'MSWin32' ) {
		# special way of installing perls!
		if ( ! install_perl_win32( $perl ) ) {
			save_logs( 'fail' );
		}

		reset_logs();
		return;
	}

	# build a default build
	if ( ! build_perl_opts( $perl, 'default' ) ) {
		save_logs( 'fail' );
	}
	reset_logs();

	# Should we also compile the matrix?
	if ( $C{matrix} ) {
		# loop over all the options we have
		foreach my $thr ( qw( thr nothr ) ) {
			foreach my $multi ( qw( multi nomulti ) ) {
				foreach my $long ( qw( long nolong ) ) {
					foreach my $malloc ( qw( mymalloc nomymalloc ) ) {
						foreach my $shrp ( qw( shrplib noshrplib ) ) {
							foreach my $dbg ( qw( debug nodebug ) ) {
								foreach my $bitness ( qw( 32 64i 64a ) ) {
									if ( ! build_perl_opts( $perl, $thr . '-' . $multi . '-' . $long . '-' . $malloc . '-' . $shrp . '-' . $dbg . '-' . $bitness ) ) {
										save_logs( 'fail' );
									}
									reset_logs();
								}
							}
						}
					}
				}
			}
		}
	}

	return;
}

sub can_build_perl {
	# We skip devel perls if it's not enabled
	if ( $stuff{perlver} =~ /^5\.(\d+)/ ) {
		if ( $1 % 2 != 0 and ! $C{devel} ) {
			do_log( 'COMPILER', 'Skipping devel version of perl-' . $stuff{perlver} . '...' );
			return 0;
		}
	}

	# Obviously, don't build 64a perl on 32bit OS!
	#Checking to see how big your pointers are...
	#
	#*** You have chosen a maximally 64-bit build,
	#*** but your pointers are only 4 bytes wide.
	#*** Please rerun Configure without -Duse64bitall.
	#*** Since you have quads, you could possibly try with -Duse64bitint.
	#*** Cannot continue, aborting.
	#[SHELLCMD] Done executing, retval = 1
	#[SHELLCMD] Executing 'cd /home/cpan/build/perl_5.18.1_thr-nomulti-long-nomymalloc-64a; make'
	#make: *** No targets specified and no makefile found.  Stop.
	#[SHELLCMD] Done executing, retval = 2
	#[PERLBUILDER] Unable to compile perl_5.18.1_thr-nomulti-long-nomymalloc-64a!
	if ( check_os_bits() == 32 and $stuff{perlopts} =~ /64a/ ) {
		do_log( 'COMPILER', 'Skipping -Duse64bitall on a 32bit platform...' );
		return 0;
	}

	# okay, list the known failures here

	# Skip problematic perls
	if ( $stuff{perlver} eq '5.6.0' or $stuff{perlver} eq '5.8.0' ) {
		# CPANPLUS won't work on 5.6.0, also some modules we want to install doesn't like 5.6.x :(
		#
		# <Apocalypse> Yeah wish me luck, last year I managed to get 5.6.0 built but couldn't get CPANPLUS to install on it
		# <Apocalypse> Maybe the situation is better now - I'm working downwards so I'll hit 5.6.X sometime later tonite after I finish 5.8.5, 5.8.4, and so on :)
		# <@kane> 5.6.1 is the minimum
		# <Apocalypse> Ah, so CPANPLUS definitely won't work on 5.6.0? I should just drop it...
		#
		# 5.8.0 blows up horribly in it's tests everywhere I try to compile it...
		do_log( 'COMPILER', 'Skipping known problematic perl-' . $stuff{perlver} . '...' );
		return 0;
	}

	# FreeBSD 5.2-RELEASE doesn't like perl-5.6.1 :(
	#
	# cc -c -I../../.. -DHAS_FPSETMASK -DHAS_FLOATINGPOINT_H -fno-strict-aliasing -I/usr/local/include -O    -DVERSION=\"0.10\"  -DXS_VERSION=\"0.10\" -DPIC -fPIC -I../../.. -DSDBM -DDUFF sdbm.c
	# sdbm.c:40: error: conflicting types for 'malloc'
	# sdbm.c:41: error: conflicting types for 'free'
	# /usr/include/stdlib.h:94: error: previous declaration of 'free' was here
	# *** Error code 1
	if ( $^O eq 'freebsd' and $stuff{perlver} eq '5.6.1' ) {
		do_log( 'COMPILER', 'Skipping perl-5.6.1 on FreeBSD...' );
		return 0;
	}

	# Analyze the options
	if ( defined $stuff{perlopts} ) {
		# NetBSD 5.0.1 cannot build -Duselongdouble:
		#
		# *** You requested the use of long doubles but you do not seem to have
		# *** the following mathematical functions needed for long double support:
		# ***     sqrtl modfl frexpl
		# *** Please rerun Configure without -Duselongdouble and/or -Dusemorebits.
		# *** Cannot continue, aborting.
		#
		# FreeBSD 5.2-RELEASE cannot build -Duselongdouble:
		#
		# *** You requested the use of long doubles but you do not seem to have
		# *** the following mathematical functions needed for long double support:
		# ***     sqrtl
		# *** Please rerun Configure without -Duselongdouble and/or -Dusemorebits.
		# *** Cannot continue, aborting.
		if ( ( $^O eq 'netbsd' or $^O eq 'freebsd' ) and $stuff{perlopts} =~ /(?<!no)long/ ) {
			do_log( 'COMPILER', 'Skipping -Duselongdouble on NetBSD/FreeBSD...' );
			return 0;
		}

		# For some reason OpenSolaris 2009.6 bombs out perl-5.8.7 with -Duse64bitall:
		#
		# *** You have chosen a maximally 64-bit build,
		# *** but your pointers are only 4 bytes wide.
		# *** Please rerun Configure without -Duse64bitall.
		# *** Since you have quads, you could possibly try with -Duse64bitint.
		# *** Cannot continue, aborting.
		# [cpan@opensolaris64 ~/perls]$ ls -l *.fail
		# -rw-r--r-- 1 cpan other 5389 2009-12-07 15:12 perl-5.8.7-nothr-multi-long-mymalloc-64a.fail
		# -rw-r--r-- 1 cpan other 5405 2009-12-07 15:39 perl-5.8.7-nothr-multi-long-nomymalloc-64a.fail
		# -rw-r--r-- 1 cpan other 5307 2009-12-07 22:48 perl-5.8.7-nothr-multi-nolong-mymalloc-64a.fail
		# -rw-r--r-- 1 cpan other 5323 2009-12-07 23:16 perl-5.8.7-nothr-multi-nolong-nomymalloc-64a.fail
		# -rw-r--r-- 1 cpan other 5311 2009-12-07 23:42 perl-5.8.7-nothr-nomulti-long-mymalloc-64a.fail
		# -rw-r--r-- 1 cpan other 5552 2009-12-07 10:30 perl-5.8.7-thr-multi-long-mymalloc-64a.fail
		# -rw-r--r-- 1 cpan other 5568 2009-12-07 10:59 perl-5.8.7-thr-multi-long-nomymalloc-64a.fail
		# -rw-r--r-- 1 cpan other 5463 2009-12-07 11:28 perl-5.8.7-thr-multi-nolong-mymalloc-64a.fail
		# -rw-r--r-- 1 cpan other 5479 2009-12-07 11:57 perl-5.8.7-thr-multi-nolong-nomymalloc-64a.fail
		if ( $^O eq 'solaris' and $stuff{perlver} eq '5.8.7' and $stuff{perlopts} =~ /64a/ ) {
			do_log( 'COMPILER', 'Skipping -Duse64bitall on perl-5.8.7 on OpenSolaris' );
			return 0;
		}
	}

	# We can build it!
	return 1;
}

sub check_os_bits {
	my $bits = Sys::Info->new->device( 'CPU' );
	if ( $bits ) {
		return $bits;
	} else {
		do_error( 'UTILS', "Unable to retrieve bitness of the CPU!" );
	}
}

# Special method to install strawberry perls for win32
sub install_perl_win32 {
	my $perl = shift;

	# First of all, check for 64bit mismatch in 32bit env
	if ( check_os_bits() == 32 and $perl =~ /64bit/ ) {
		do_log( 'COMPILER', "Skipping $perl due to 32bit system!" );
		return 0;
	}

	$stuff{perlver} = $perl;
	$stuff{perldist} = "strawberry_$stuff{perlver}";

	# Okay, is this perl installed?
	my $path = File::Spec->catdir( $C{home}, 'perls', $stuff{perldist} );
	if ( ! -d $path ) {
		# We need to download the zip!
		my $localpath = File::Spec->catfile( $C{home}, 'build', 'PERL.zip' );
		if ( -f $localpath ) {
			do_unlink( $localpath );
		}
		do_shellcommand( "lwp-mirror ftp://$C{server}/STRAWBERRY_PERL/strawberry-perl-" . $perl . ".zip $localpath" );

		# Okay, unzip the archive
		if ( ! do_archive_extract( $localpath, $path ) ) {
			return 0;
		} else {
			do_unlink( $localpath );
		}
	} else {
		# all done with configuring?
		if ( -e File::Spec->catfile( $path, 'ready.smoke' ) ) {
			do_log( 'COMPILER', "$stuff{perldist} is ready to smoke..." );
			return 1;
		} else {
			do_log( 'COMPILER', "$stuff{perldist} is already built..." );
		}
	}

	# move this perl to c:\strawberry
	if ( -d "C:\\strawberry" ) {
		do_error( 'UTILS', 'Old Strawberry Perl found in C:\\strawberry, please fix it!' );
	}
	do_mv( $path, "C:\\strawberry" );

	my $ret = customize_perl();

	# Move the strawberry install to it's regular place
	do_mv( "C:\\strawberry", $path );

	# finalize the perl install!
	# This needs to be done because customize_perl calls it while the dir is still in c:\strawberry!
	if ( $ret and ! finalize_perl() ) {
		return 0;
	}

	return $ret;
}

sub build_perl_opts {
	# set the perl stuff
	$stuff{perlver} = shift;
	$stuff{perlopts} = shift;
	$stuff{perldist} = "perl_$stuff{perlver}_$stuff{perlopts}";

	# Skip problematic perls
	if ( ! can_build_perl() ) {
		# TODO skip for testing
		return 0;
	}

	# have we already compiled+installed this version?
	my $path = File::Spec->catdir( $C{home}, 'perls', $stuff{perldist} );
	if ( ! -d $path ) {
		# did the compile fail?
		if ( -e File::Spec->catfile( $C{home}, 'perls', "$stuff{perldist}.fail" ) ) {
			do_log( 'COMPILER', "$stuff{perldist} already failed, skipping..." );
			return 0;
		}

		# kick off the build process!
		my $ret = do_build();

		# cleanup the build dir ( lots of space! )
		do_rmdir( File::Spec->catdir( $C{home}, 'build', $stuff{perldist} ) );

		if ( ! $ret ) {
			# failed something during compiling, move on!
			return 0;
		}
	} else {
		# all done with configuring?
		if ( -e File::Spec->catfile( $path, 'ready.smoke' ) ) {
			do_log( 'COMPILER', "$stuff{perldist} is ready to smoke..." );
			return 1;
		} else {
			do_log( 'COMPILER', "$stuff{perldist} is already built..." );
		}
	}

	return customize_perl();
}

sub customize_perl {
	do_log( 'COMPILER', "Firing up the $stuff{perldist} installer..." );

	# do we have CPANPLUS already extracted?
	if ( ! do_initCPANP_BOXED() ) {
		return 0;
	}

	# we go ahead and configure CPANPLUS for this version :)
	if ( ! do_installCPANPLUS() ) {
		return 0;
	}

	# finalize the perl install!
	# Ah, if we're on win32 this will not work...
	if ( $^O ne 'MSWin32' ) {
		if ( ! finalize_perl() ) {
			return 0;
		}
	}

	# we're done!
	return 1;
}

sub finalize_perl {
	# Get rid of the man directory!
	# TODO <@vincent> -Dman1dir=none -Dman3dir=none
	# <Khisanth> makepl_arg         [INSTALLMAN1DIR=none INSTALLMAN3DIR=none]
	my $path = File::Spec->catdir( $C{home}, 'perls', $stuff{perldist} );
	my $mandir = File::Spec->catdir( $path, 'man' );
	if ( -d $mandir ) {
		do_rmdir( $mandir );
	}

	# Special actions for Strawberry Perl on win
	if ( $^O eq 'MSWin32' ) {
		# Strawberry Perl places stuff in different paths!
		# C:\cpansmoke\perls\strawberry_perl_5.10.1.1_default\perl\lib\pods
		foreach my $d ( qw( man html lib\\pods ) ) {
			my $dir = File::Spec->catdir( $path, 'perl', $d );
			if ( -d $dir ) {
				do_rmdir( $dir );
			}
		}

		# Strawberry Perl adds "licenses" directory that can be safely removed
		my $licdir = File::Spec->catdir( $path, 'licenses' );
		if ( -d $licdir ) {
			do_rmdir( $licdir );
		}
	}

	# get rid of the default pod...
#	/home/cpan/perls/perl-5.10.1-default/lib/5.10.1/pod/perlwin32.pod
#	/home/cpan/perls/perl-5.10.1-default/lib/5.10.1/pod/perlxs.pod
#	/home/cpan/perls/perl-5.10.1-default/lib/5.10.1/pod/perlxstut.pod
#	/home/cpan/perls/perl-5.10.1-default/lib/5.10.1/pod/a2p.pod
	my $perlver = $stuff{perlver};
	$perlver =~ s/\-.+$//;	# Get rid of the 5.12.0-RC0 stuff
	my $poddir = File::Spec->catdir( $path, 'lib', $perlver, 'pod' );
	if ( -d $poddir ) {
		do_rmdir( $poddir );
	}

	# Kill all pod files
	my @podfiles = File::Find::Rule->file()->name( '*.pod' )->in( $path );
	foreach my $pod ( @podfiles ) {
		do_unlink( $pod );
	}

	# we're really done, dump the log into the ready.smoke file!
	do_log( 'COMPILER', "All done with $stuff{perldist}..." );
	do_replacefile( File::Spec->catfile( $path, 'ready.smoke' ), join( "\n", @LOGS ), 1 );

	return 1;
}

sub do_prebuild {
	# get the tarball location on the CPAN mirror
	my $cpan_path = perl_tarballs( $stuff{perlver} );
	if ( ! defined $cpan_path or ! exists $cpan_path->{'tar.gz'} ) {
		# TODO use bz2 or whatever?
		do_log( 'UTILS', "Unable to obtain Perl tarball info for $stuff{perlver}!" );
		return 0;
	}
	my $localpath = File::Spec->catfile( $C{home}, 'build', 'PERL.tar.gz' );
	if ( -f $localpath ) {
		do_unlink( $localpath );
	}
	do_shellcommand( "lwp-mirror ftp://$C{server}$C{s_ftpdir}authors/id/" . $cpan_path->{'tar.gz'} . " $localpath" );

	# extract the tarball!
#	[PERLBUILDER] Firing up the perl-5.11.5-default installer...
#	[PERLBUILDER] perl-5.11.5-default is ready to smoke...
#	[PERLBUILDER] Firing up the perl-5.11.4-default installer...
#	[PERLBUILDER] Preparing to build perl-5.11.4-default
#	[EXTRACTOR] Preparing to extract '/export/home/cpan/build/perl-5.11.4.tar.gz'
#	Could not open file '/export/home/cpan/build/perl-5.11.4/AUTHORS': Permission denied at /usr/perl5/site_perl/5.8.4/Archive/Extract.pm line 812
#	Unable to read '/export/home/cpan/build/perl-5.11.4.tar.gz': Could not open file '/export/home/cpan/build/perl-5.11.4/AUTHORS': Permission denied at ./compile.pl line 1072
	# Just remove any old dir that was there ( script exited in the middle so it was not cleaned up )
	my $extract_dir = File::Spec->catdir( $C{home}, 'build', "perl-$stuff{perlver}" );
	if ( -d $extract_dir ) {
		do_rmdir( $extract_dir );
	}
	if ( ! do_archive_extract( $localpath, File::Spec->catdir( $C{home}, 'build' ) ) ) {
		return 0;
	}
	do_unlink( $localpath );

	# remove the old dir so we have a consistent build process
	my $build_dir = File::Spec->catdir( $C{home}, 'build', $stuff{perldist} );
	if ( -d $build_dir ) {
		do_rmdir( $build_dir );
	}
	do_mv( $extract_dir, $build_dir );

	# We defer to the excellent Devel::PatchPerl to do our dirty work :)
	eval {
		Devel::PatchPerl->patch_source( $stuff{perlver}, $build_dir );
	};
	if ( $@ ) {
		do_log( 'COMPILER', "Error in patching source: $@" );
		return 0;
	}

	# TODO this sucks, but lib/Benchmark.t usually takes forever and fails unnecessarily on my loaded box...
	# Also, most time-related tests BOMB out because of the dang VM timing semantics...
	my @fails = ( [ 'lib', 'Benchmark.t' ] );
	push( @fails, [ 't', 'op', 'time.t' ], [ 'op', 'time.t' ] );
	push( @fails, [ 'ext', 'Time-HiRes', 't', 'HiRes.t' ] );
	push( @fails, [ 'cpan', 'Time-HiRes', 't', 'HiRes.t' ] );
	push( @fails, [ 't', 'op', 'alarm.t' ], [ 'op', 'alarm.t' ] );

	# remove them!
	my $manipath = File::Spec->catfile( $build_dir, 'MANIFEST' );
	if ( scalar @fails ) {
		# TODO since we are removing files, we have to remove this too or find a way to fix it!
		push( @fails, [ 't', 'porting', 'maintainers.t' ] );
	}
	foreach my $t ( @fails ) {
		my $testpath = File::Spec->catfile( $build_dir, @$t );
		if ( -f $testpath ) {
			do_unlink( $testpath );

			# argh, we have to munge MANIFEST
			do_shellcommand( "perl -nli -e 'print if ! /^" . quotemeta( join( '/', @$t ) ) . "/' $manipath" );
		}
	}

	return 1;
}

sub do_rmdir {
	my( $dir, $quiet ) = @_;

	do_log( 'RMDIR', "Executing rmdir( $dir )" ) if ! $quiet;

	File::Path::Tiny::rm( $dir ) or do_error( 'RMDIR', "Unable to rmdir '$dir': $!" );

	return;
}

sub do_mkdir {
	my( $dir, $quiet ) = @_;

	do_log( 'MKDIR', "Executing mkdir( $dir )" ) if ! $quiet;

	File::Path::Tiny::mk( $dir ) or do_error( 'MKDIR', "Unable to mkdir '$dir': $!" );

	return;
}

sub do_unlink {
	my( $file, $quiet ) = @_;

	do_log( 'UNLINK', "Executing unlink( $file )" ) if ! $quiet;

	unlink( $file ) or do_error( 'UNLINK', "Unable to unlink '$file': $!" );

	return;
}

sub do_initCPANP_BOXED {
	do_log( 'CPANPLUS', "Configuring CPANPLUS::Boxed..." );

	# Execute a query against our CPANIDX server, this is the default version as of 10/18/14 :)
	my $cpanp_ver = '0.9152';
	my $cpanp_tarball = 'B/BI/BINGOS/CPANPLUS-0.9152.tar.gz';
#$ lwp-request http://smoker-master:11110/CPANIDX/yaml/mod/CPANPLUS
#---
#-
#  cpan_id: BINGOS
#  dist_file: B/BI/BINGOS/CPANPLUS-0.9152.tar.gz
#  dist_name: CPANPLUS
#  dist_vers: '0.9152'
#  mod_name: CPANPLUS
#  mod_vers: '0.9152'
	my $output = do_shellcommand( "lwp-request http://$C{server}:$C{s_cpanidx_port}$C{s_cpanidx_path}yaml/mod/CPANPLUS" );
	$output = join "\n", @$output;
	if ( $output =~ /dist_vers\:\s+\'(.+)\'$/m ) {
		$cpanp_ver = $1;
	} else {
		do_log( 'CPANPLUS', "Unable to retrieve CPANPLUS version: $output" );
	}
	if ( $output =~ /dist_file\:\s+(.+)$/m ) {
		$cpanp_tarball = $1;
	} else {
		do_log( 'CPANPLUS', "Unable to retrieve CPANPLUS tarball: $output" );
	}

	# do we have CPANPLUS already extracted?
	my $cpandir = File::Spec->catdir( $C{home}, "CPANPLUS-$cpanp_ver" );
	if ( -d $cpandir ) {
		do_rmdir( $cpandir );
	}

	# do we have the tarball?
	my $cpantarball = File::Spec->catfile( $C{home}, ( File::Spec->splitpath( $cpanp_tarball ) )[2] );
	if ( ! -f $cpantarball ) {
		# get it!
		do_shellcommand( "lwp-mirror ftp://$C{server}$C{s_ftpdir}authors/id/$cpanp_tarball $cpantarball" );
	}

	# extract it!
	if ( ! do_archive_extract( $cpantarball, $C{home} ) ) {
		return 0;
	}

	# configure the Boxed.pm file
	$stuff{cpanp_ver} = $cpanp_ver;
	do_installCPANP_BOXED_config();

	# force an update
	if ( ! do_cpanpboxed_action( "x --update_source" ) ) {
		return 0;
	}

	return 1;
}

sub do_archive_extract {
	my $archive = shift;
	my $path = shift;

	do_log( 'EXTRACTOR', "Preparing to extract '$archive'" );

	require Archive::Extract;
	my $a = Archive::Extract->new( archive => $archive );
	if ( ! defined $a ) {
		do_log( 'EXTRACTOR', "Unable to initialize!" );
		return 0;
	}

	if ( defined $path ) {
		if ( ! $a->extract( to => $path ) ) {
			do_log( 'EXTRACTOR', "Unable to extract '$archive' to '$path': " . $a->error );
			return 0;
		}
	} else {
		if ( ! $a->extract ) {
			do_log( 'EXTRACTOR', "Unable to extract '$archive': " . $a->error );
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
###  Configuration for CPANPLUS::Config::Boxed
###
###############################################

#last changed: XXXTIMEXXX

=pod

=head1 NAME

CPANPLUS::Config::Boxed

=head1 DESCRIPTION

This is a CPANPLUS configuration file.

=cut

package CPANPLUS::Config::Boxed;

use strict;

sub setup {
	my $conf = shift;

	$conf->set_conf( allow_build_interactivity => 0 );
	$conf->set_conf( base => 'XXXCATDIR-XXXPATHXXX/CPANPLUS-XXXCPANPLUSXXX/.cpanplus/XXXUSERXXXXXX' );
	$conf->set_conf( buildflags => 'XXXBUILDFLAGSXXX' );
	$conf->set_conf( cpantest => 0 );
	$conf->set_conf( cpantest_mx => '' );
	$conf->set_conf( cpantest_reporter_args => {} );
	$conf->set_conf( debug => 1 );
	$conf->set_conf( dist_type => '' );
	$conf->set_conf( email => 'XXXCONFIG-EMAILXXX' );
	$conf->set_conf( enable_custom_sources => 0 );
	$conf->set_conf( extractdir => '' );
	$conf->set_conf( fetchdir => '' );
	$conf->set_conf( flush => 1 );
	$conf->set_conf( force => 0 );
	$conf->set_conf( hosts => [
		{
			'path' => 'XXXCONFIG-S_FTPDIRXXX',
			'scheme' => 'ftp',
			'host' => 'XXXCONFIG-SERVERXXX',
		},
	] );
	$conf->set_conf( lib => [] );
	$conf->set_conf( makeflags => 'XXXMAKEFLAGSXXX' );
	$conf->set_conf( makemakerflags => '' );
	$conf->set_conf( md5 => 1 );
	$conf->set_conf( no_update => 1 );
	$conf->set_conf( passive => 1 );
	$conf->set_conf( prefer_bin => XXXPREFERBINXXX );
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

# Because we're bootstrapping, Module::Build and friends often aren't "ready"
	$conf->set_conf( prefer_makefile => 1 );

	$conf->set_program( editor => undef );
	$conf->set_program( make => 'XXXWHICH-makeXXX' );
	$conf->set_program( pager => 'XXXWHICH-lessXXX' );
	$conf->set_program( perlwrapper => 'XXXCATDIR-XXXPATHXXX/CPANPLUS-XXXCPANPLUSXXX/bin/cpanp-run-perlXXX' );
	$conf->set_program( shell => 'XXXWHICH-bashXXX' );
	$conf->set_program( sudo => undef );

	return 1;
}
1;
END

	# transform the XXXargsXXX
	$boxed = do_replacements( $boxed );

	# save it!
	my $cpanp_dir;
	if ( $^O eq 'MSWin32' ) {
		$cpanp_dir = File::Spec->catdir( $C{home}, "CPANPLUS-$stuff{cpanp_ver}", '.cpanplus', $ENV{USERNAME}, 'lib', 'CPANPLUS', 'Config' );
	} else {
		$cpanp_dir = File::Spec->catdir( $C{home}, "CPANPLUS-$stuff{cpanp_ver}", '.cpanplus', $ENV{USER}, 'lib', 'CPANPLUS', 'Config' );
	}
	do_mkdir( $cpanp_dir );
	do_replacefile( File::Spec->catfile( $cpanp_dir, 'Boxed.pm' ), $boxed );

	return;
}

sub do_replacements {
	my $str = shift;

	# basic stuff
	if ( $^O eq 'MSWin32' ) {
		# On MSWin32, we use USERNAME instead of USER...
		$str =~ s/XXXUSERXXX/$ENV{USERNAME}/g;

		# We cannot use binaries on MSWin32!
		$str =~ s/XXXPREFERBINXXX/0/g;

		# Naturally, on MSWin32 we need to use the strawberry path...
		$str =~ s/XXXPERLWRAPPERXXX/C:\\\\strawberry\\\\perl\\\\bin\\\\cpanp-run-perl\.BAT/g;
	} else {
		$str =~ s/XXXUSERXXX/$ENV{USER}/g;
		$str =~ s/XXXPREFERBINXXX/1/g;
		$str =~ s/XXXPERLWRAPPERXXX/XXXCATDIR-XXXPATHXXX\/perls\/XXXPERLDISTXXX\/bin\/cpanp-run-perlXXX/g;
	}
	$str =~ s/XXXPATHXXX/do_replacements_slash( $C{home} )/ge;

#<Apocalypse> BinGOs: Wondering what you put in the CPANPLUS config on your smoking setup for makemakerflags and buildflags
#<@BinGOs> s conf makeflags UNINST=1 and s conf buildflags uninst=1
#<Apocalypse> Why the uninst? You chown root the perl dirs so nothing can instal there, right?
#<Apocalypse> Or is that for the initial perl build stage, where you want to make sure the modules you install override any core modules and they get deleted?
#<@BinGOs> habit
#<@BinGOs> and when I am updating
	$str =~ s/XXXBUILDFLAGSXXX/uninst=1/g;
	$str =~ s/XXXMAKEFLAGSXXX/UNINST=1/g;

	$str =~ s/XXXPERLDISTXXX/$stuff{perldist}/g;
	$str =~ s/XXXCPANPLUSXXX/$stuff{cpanp_ver}/g;
	$str =~ s/XXXTIMEXXX/scalar localtime()/ge;

	# find binary locations
	$str =~ s/XXXWHICH-([\w\-]+)XXX/do_replacements_slash( get_binary_path( $1 ) )/ge;

	# Smart config %C{ foo } support
	$str =~ s/XXXCONFIG\-(\w+)XXX/do_replacements_config( $1 )/ge;

	# Smart file::spec->catdir support
	$str =~ s/XXXCATDIR\-(.+)XXX/do_replacements_slash( do_replacements_catdir( $1 ) )/ge;

	return $str;
}

sub do_replacements_config {
	my $str = lc( shift );

	if ( exists $C{ $str } and defined $C{ $str } ) {
		return $C{ $str };
	} else {
		do_error( 'CONFIGER', "Unknown config key: $str" );
	}
}

sub do_replacements_catdir {
	my $str = shift;

	# split the paths
	my @path = split( '/', $str );
	my @newpath;
	foreach my $p ( @path ) {
		push( @newpath, do_replacements( $p ) );
	}

	# Okay, file::spec it!
	return File::Spec->catdir( @newpath );
}

# implemented this because quotemeta isn't what we wanted...
sub do_replacements_slash {
	my $str = shift;

	$str =~ s|(?<!\\)\\(?!\\)|\\\\|g;
	return $str;
}

sub get_binary_path {
	my $binary = shift;

	# do some munging, especially for the CPANPLUS config file
	if ( $^O eq 'MSWin32' ) {
		if ( $binary eq 'make' ) {
			$binary = 'dmake';
		}
		if ( $binary eq 'less' ) {
			$binary = 'more';
		}
		if ( $binary eq 'bash' ) {
			$binary = 'cmd';
		}
	}

	my $path = which( $binary );
	if ( defined $path ) {
		chomp( $path );
		return $path;
	} else {
		return '';
	}
}

sub do_installCPANPLUS {
	do_log( 'CPANPLUS', "Configuring CPANPLUS..." );

	# Install CPANPLUS and it's stuff!
	if ( ! do_cpanpboxed_action( "s selfupdate all" ) ) {
		return 0;
	}

	# Install the toolchain modules
	if ( ! do_cpanpboxed_action( "i " . join( ' ', @{ get_CPANPLUS_toolchain() } ) ) ) {
		return 0;
	}

	# configure the installed CPANPLUS
	do_installCPANPLUS_config();

	return 1;
}

sub get_CPANPLUS_toolchain {
	# List taken from CPANPLUS::Internals::Constants::Report v0.9152
	# use constant REPORT_TOOLCHAIN_VERSIONS
	# We remove CPANPLUS from this list because it's redundant :)
	# We remove 'version' because it's perl-core
	# TODO is it possible to get this value from CPANPLUS automatically?
	my @toolchain_modules = qw(
		CPANPLUS::Dist::Build
		Cwd
		ExtUtils::CBuilder
		ExtUtils::Command
		ExtUtils::Install
		ExtUtils::MakeMaker
		ExtUtils::Manifest
		ExtUtils::ParseXS
		File::Spec
		Module::Build
		Pod::Parser
		Pod::Simple
		Test::Harness
		Test::More
	);

	# Add Metabase and our YACSmoke stuff
	push( @toolchain_modules, qw( CPANPLUS::YACSmoke Test::Reporter::Transport::Socket ) );

	# Add our CPANIDX stuff
	push( @toolchain_modules, qw( CPANPLUS::Internals::Source::CPANIDX ) );

	# Add other useful toolchain modules
	push( @toolchain_modules, qw( File::Temp ) );

	# On MSWin32 systems, we cannot use binaries so we have to install this!
	if ( $^O eq 'MSWin32' ) {
		push( @toolchain_modules, qw( Archive::Zip Archive::Tar ) );
	}

	return \@toolchain_modules;
}

# Look at do_installCPANP_BOXED_config for more details
sub do_installCPANPLUS_config {
# TODO seems like this causes weird caching issues - better to split off the stuff for now...
#	$conf->set_conf( fetchdir => 'XXXCATDIR-XXXPATHXXX/.cpanplus/authorsXXX' );

# We let CPANPLUS automatically figure it out!
#	$conf->set_conf( prefer_makefile => 1 );

# We now use CPANIDX to speed up our smoking!
#	$conf->set_conf( source_engine => 'CPANPLUS::Internals::Source::Memory' );

	# configure the CPANPLUS config
	my $cpanplus = <<'END';
###############################################
###
###  Configuration for CPANPLUS::Config::User
###
###############################################

#last changed: XXXTIMEXXX

=pod

=head1 NAME

CPANPLUS::Config::User

=head1 DESCRIPTION

This is a CPANPLUS configuration file.

=cut

package CPANPLUS::Config::User;

use strict;

sub setup {
	my $conf = shift;

	$conf->set_conf( allow_build_interactivity => 0 );
	$conf->set_conf( base => 'XXXCATDIR-XXXPATHXXX/cpanp_conf/XXXPERLDISTXXX/.cpanplusXXX' );
	$conf->set_conf( buildflags => 'XXXBUILDFLAGSXXX' );
	$conf->set_conf( cpantest => 1 );
	$conf->set_conf( cpantest_mx => '' );

# The Socket proxied transport, best for my setup - thanks BinGOs!
	$conf->set_conf( cpantest_reporter_args => {
		transport => 'Socket',
		transport_args => [
			host => 'XXXCONFIG-SERVERXXX',
			port => 'XXXCONFIG-S_CT_PORTXXX',
		],
	} );

	$conf->set_conf( debug => 1 );
	$conf->set_conf( dist_type => '' );
	$conf->set_conf( email => 'XXXCONFIG-EMAILXXX' );
	$conf->set_conf( enable_custom_sources => 0 );
	$conf->set_conf( extractdir => '' );
	$conf->set_conf( fetchdir => '' );
	$conf->set_conf( flush => 1 );
	$conf->set_conf( force => 0 );
	$conf->set_conf( hosts => [
		{
			'path' => 'XXXCONFIG-S_FTPDIRXXX',
			'scheme' => 'ftp',
			'host' => 'XXXCONFIG-SERVERXXX',
		},
	] );
	$conf->set_conf( lib => [] );
	$conf->set_conf( makeflags => 'XXXMAKEFLAGSXXX' );
	$conf->set_conf( makemakerflags => '' );
	$conf->set_conf( md5 => 1 );
	$conf->set_conf( no_update => 1 );
	$conf->set_conf( passive => 1 );
	$conf->set_conf( prefer_bin => XXXPREFERBINXXX );
	$conf->set_conf( prereqs => 1 );
	$conf->set_conf( shell => 'CPANPLUS::Shell::Default' );
	$conf->set_conf( show_startup_tip => 0 );
	$conf->set_conf( signature => 0 );
	$conf->set_conf( skiptest => 0 );
	$conf->set_conf( source_engine => 'CPANPLUS::Internals::Source::CPANIDX' );
	$conf->set_conf( storable => 1 );
	$conf->set_conf( timeout => 300 );
	$conf->set_conf( verbose => 1 );
	$conf->set_conf( write_install_logs => 0 );

	$conf->set_program( editor => undef );
	$conf->set_program( make => 'XXXWHICH-makeXXX' );
	$conf->set_program( pager => 'XXXWHICH-lessXXX' );
	$conf->set_program( perlwrapper => 'XXXPERLWRAPPERXXX' );
	$conf->set_program( shell => 'XXXWHICH-bashXXX' );
	$conf->set_program( sudo => undef );

	return 1;
}
1;
END

	# transform the XXXargsXXX
	$cpanplus = do_replacements( $cpanplus );

	# TODO save the old cpansmoke.dat files?

	# blow away the old cpanplus dir if it's there
	my $oldcpanplus = File::Spec->catdir( $C{home}, 'cpanp_conf', $stuff{perldist} );
	if ( -d $oldcpanplus ) {
		do_rmdir( $oldcpanplus );
	}

	# save it!
	my $cpanp_dir = File::Spec->catdir( $oldcpanplus, '.cpanplus', 'lib', 'CPANPLUS', 'Config' );
	do_mkdir( $cpanp_dir );
	do_replacefile( File::Spec->catfile( $cpanp_dir, 'User.pm' ), $cpanplus );

	return;
}

sub do_cpanpboxed_action {
	my( $action ) = @_;

	# use default answer to prompts
	local $ENV{PERL_MM_USE_DEFAULT} = 1;
	local $ENV{PERL_EXTUTILS_AUTOINSTALL} = '--defaultdeps';
	local $ENV{TMPDIR} = File::Spec->catdir( $C{home}, 'tmp' );

	# Special way for win32
	if ( $^O eq 'MSWin32' ) {
		# Make sure we have the proper path
		local $ENV{PATH} = cleanse_strawberry_path();

		return analyze_cpanp_install( $action, do_shellcommand( "perl " . File::Spec->catfile( $C{home}, "CPANPLUS-$stuff{cpanp_ver}", 'bin', 'cpanp-boxed' ) . " $action" ) );
	} else {
		return analyze_cpanp_install( $action, do_shellcommand( File::Spec->catfile( $C{home}, 'perls', $stuff{perldist}, 'bin', 'perl' ) . " " . File::Spec->catfile( $C{home}, "CPANPLUS-$stuff{cpanp_ver}", 'bin', 'cpanp-boxed' ) . " $action" ) );
	}
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
			# Argh, detect "core" module failures and ignore them
#			Installing ExtUtils::Install (1.54)
#			[ERROR] The core Perl 5.011005 module 'ExtUtils::Install' (1.55) is more recent than the latest release on CPAN (1.54). Aborting install.
#			...
#			Module 'CPANPLUS::Dist::Build' installed successfully
#			Module 'Cwd' installed successfully
#			Module 'ExtUtils::CBuilder' installed successfully
#			Module 'ExtUtils::Command' installed successfully
#			Error installing 'ExtUtils::Install'
#			Module 'ExtUtils::MakeMaker' installed successfully
#			Module 'ExtUtils::Manifest' installed successfully
#			Module 'ExtUtils::ParseXS' installed successfully
#			Module 'File::Spec' installed successfully
#			Module 'Module::Build' installed successfully
#			Module 'Test::Harness' installed successfully
#			Module 'Test::More' installed successfully
#			Module 'CPANPLUS::YACSmoke' installed successfully
#			Module 'Test::Reporter::Transport::Socket' installed successfully
#			Module 'File::Temp' installed successfully
#			Problem installing one or more modules
#
#			[SHELLCMD] Done executing, retval = 0
#			[LOGS] Saving log to '/home/cpan/perls/perl-5.11.5-default.fail'
			if ( $ret->[-1] =~ /Problem\s+installing\s+one\s+or\s+more\s+modules/ ) {
				# Argh, look for status of failed modules
				my @fail;
				my $line = -2;	# skip the "Problem installing" line
				while ( 1 ) {
					if ( length $ret->[$line] <= 1 ) {
						$line--;
					} elsif ( $ret->[$line] =~ /^Module\s+\'/ ) {
						$line--;
					} elsif ( $ret->[$line] =~ /^Error\s+installing\s+\'([^\']+)\'/ ) {
						push( @fail, $1 );
						$line--;
					} else {
						last;
					}
				}
				if ( @fail ) {
					foreach my $m ( @fail ) {
						# Did it abort because of core perl?
						if ( ! fgrep( 'ERROR.+The\s+core\s+Perl.+' . $m . '.+latest\s+release\s+on\s+CPAN.+Aborting\s+install', $ret ) ) {
							do_log( 'CPANPLUS', 'Detected error while installing modules' );
							return 0;
						}
					}

					# Got here, all fails were core, ignore it!
					return 1;
				}
			} else {
				return 0;
			}
		}
	} elsif ( $action =~ /^s/ ) {
		# TODO analyse this?
		return 1;
	} elsif ( $action =~ /^x/ ) {
#		[root@freebsd64 ~]# cpanp x --update_source
#		[MSG] Checking if source files are up to date
#		[MSG] Updating source file '01mailrc.txt.gz'
#		[MSG] Trying to get 'ftp://192.168.0.200/CPAN/authors/01mailrc.txt.gz'
#		[MSG] Updating source file '03modlist.data.gz'
#		[MSG] Trying to get 'ftp://192.168.0.200/CPAN/modules/03modlist.data.gz'
#		[MSG] Updating source file '02packages.details.txt.gz'
#		[MSG] Trying to get 'ftp://192.168.0.200/CPAN/modules/02packages.details.txt.gz'
#		[MSG] No '/root/.cpanplus/custom-sources' dir, skipping custom sources
#		[MSG] Rebuilding author tree, this might take a while
#		[MSG] Rebuilding module tree, this might take a while
#		[MSG] Writing compiled source information to disk. This might take a little while.
#		[root@freebsd64 ~]#
		if ( $ret->[-1] =~ /Writing\s+compiled\s+source\s+information/ ) {
			return 1;
		} else {
			# older CPANPLUS didn't write out the "compiled source" line...
#			[MSG] Trying to get 'ftp://192.168.0.200/CPAN/modules/02packages.details.txt.gz'
#			[MSG] Rebuilding author tree, this might take a while
#			[MSG] Rebuilding module tree, this might take a while
#			[LOGS] Saving log to '/home/cpan/perls/perl-5.6.1-default.fail'
			if ( $ret->[-1] =~ /Rebuilding\s+module\s+tree/ ) {
				return 1;
			} else {
				# Argh, 5.6.X needs a bit more tweaking
#				[MSG] Rebuilding author tree, this might take a while
#				You do not have 'Compress::Zlib' installed - Please install it as soon as possible. at /export/home/cpan/CPANPLUS-0.9002/bin/../lib/CPANPLUS/Internals/Source.pm line 544
#				[MSG] Rebuilding module tree, this might take a while
#				You do not have 'Compress::Zlib' installed - Please install it as soon as possible. at /export/home/cpan/CPANPLUS-0.9002/bin/../lib/CPANPLUS/Internals/Source.pm line 793
#				You do not have 'Compress::Zlib' installed - Please install it as soon as possible. at /export/home/cpan/CPANPLUS-0.9002/bin/../lib/CPANPLUS/Internals/Source.pm line 630
#				[SHELLCMD] Done executing, retval = 0
#				[LOGS] Saving log to '/export/home/cpan/perls/perl-5.6.1-default.fail'
				if ( $ret->[-1] =~ /You\s+do\s+not\s+have\s+\'Compress::Zlib\'\s+installed/ ) {
					return 1;
				} else {
					do_log( 'CPANPLUS', 'Detected error while indexing' );
					return 0;
				}
			}
		}
	} elsif ( $action =~ /^u/ ) {
#		root@blackhole:/home/apoc# cpanp u Term::Title --force
#		Uninstalling 'Term::Title'
#		[MSG] Unlinking '/usr/local/share/perl/5.10.0/Term/Title.pod'
#		Running [/usr/bin/perl -eunlink+q[/usr/local/share/perl/5.10.0/Term/Title.pod]]...
#		[MSG] Unlinking '/usr/local/share/perl/5.10.0/Term/Title.pm'
#		Running [/usr/bin/perl -eunlink+q[/usr/local/share/perl/5.10.0/Term/Title.pm]]...
#		[MSG] Unlinking '/usr/local/man/man3/Term::Title.3pm'
#		Running [/usr/bin/perl -eunlink+q[/usr/local/man/man3/Term::Title.3pm]]...
#		[MSG] Unlinking '/usr/local/lib/perl/5.10.0/auto/Term/Title/.packlist'
#		Running [/usr/bin/perl -eunlink+q[/usr/local/lib/perl/5.10.0/auto/Term/Title/.packlist]]...
#		Module 'Term::Title' uninstalled successfully
#		All modules uninstalled successfully
#
#		root@blackhole:/home/apoc#
		if ( $ret->[-1] =~ /All\s+modules\s+uninstalled\s+successfully/ ) {
			return 1;
		} else {
			do_log( 'CPANPLUS', 'Detected error while uninstalling modules' );
			return 0;
		}
	} else {
		# unknown action!
		return 0;
	}
}

sub do_cpanp_action {
	my( $perl, $action ) = @_;

	# If perl is undef, we use the system perl!
	local $ENV{APPDATA} = File::Spec->catdir( $C{home}, 'cpanp_conf', $perl ) if defined $perl;
	local $ENV{APPDATA} = $C{home} if ! defined $perl;

	# use default answer to prompts
	local $ENV{PERL_MM_USE_DEFAULT} = 1;
	local $ENV{PERL_EXTUTILS_AUTOINSTALL} = '--defaultdeps';
	local $ENV{TMPDIR} = File::Spec->catdir( $C{home}, 'tmp' );
	local $ENV{PERL5_CPANIDX_URL} = 'http://' . $C{server} . ':' . $C{s_cpanidx_port} . $C{s_cpanidx_path};

	# special way for MSWin32...
	if ( $^O eq 'MSWin32' ) {
		local $ENV{PATH} = cleanse_strawberry_path() if defined $perl;

		return analyze_cpanp_install( $action, do_shellcommand( get_binary_path( 'cpanp' ) . ' ' . $action ) );
	} else {
		if ( defined $perl ) {
			return analyze_cpanp_install( $action, do_shellcommand( File::Spec->catfile( $C{home}, 'perls', $perl, 'bin', 'perl' ) . " " . File::Spec->catfile( $C{home}, 'perls', $perl, 'bin', 'cpanp' ) . " $action" ) );
		} else {
			return analyze_cpanp_install( $action, do_shellcommand( "perl $action" ) );
		}
	}
}

sub cleanse_strawberry_path {
	my @path = split( ';', $ENV{PATH} );
	my @newpath;
	foreach my $p ( @path ) {
		if ( $p !~ /bootperl/ and $p !~ /strawberry/ ) {
			push( @newpath, $p );
		}
	}
	push( @newpath, "C:\\strawberry\\c\\bin" );
	push( @newpath, "C:\\strawberry\\perl\\bin" );
	return join( ';', @newpath );
}

sub do_shellcommand {
	my $cmd = shift;

	# TODO make the output indented for readability, but don't do it on the original data!
	# we need to tell tee_merged to automatically insert a \t before each line...
	my( $output, $retval );
	do_log( 'SHELLCMD', "Executing '$cmd'" );

	# TODO work with DAGOLDEN to figure out this crapola on my FreeBSD vm...
	# It happens under heavy load, under no load, under whatever load :(
#	[SHELLCMD] Executing '/home/cpan/perls/perl-5.8.2-default/bin/perl /home/cpan/perls/perl-5.8.2-default/bin/cpanp s selfupdate all'
#	Timed out waiting for subprocesses to start at /usr/local/lib/perl5/site_perl/5.8.9/Capture/Tiny.pm line 221
#        Capture::Tiny::_wait_for_tees('HASH(0x61ed58)') called at /usr/local/lib/perl5/site_perl/5.8.9/Capture/Tiny.pm line 286
#        Capture::Tiny::_capture_tee(1, 0, 1, 'CODE(0x61ec88)') called at ./compile.pl line 1657
#        main::do_shellcommand('/home/cpan/perls/perl-5.8.2-default/bin/perl /home/cpan/perls...') called at ./compile.pl line 1622
#        main::do_cpanp_action('perl-5.8.2-default', 's selfupdate all') called at ./compile.pl line 214
#        main::__ANON__('perl-5.8.2-default') called at ./compile.pl line 386
#        main::iterate_perls('CODE(0x966b78)') called at ./compile.pl line 253
#        main::prompt_action() called at ./compile.pl line 92
	my $fails = 1;
	until ( ! $fails ) {
		eval {
			$output = tee_merged { $retval = system( $cmd ) };
		};
		if ( ! $@ ) {
			$fails = 0;
		} else {
			do_log( 'SHELLCMD', "Detected Capture::Tiny FAIL, re-trying command" );

			# ABORT if we fail 3 straight times...
			if ( $fails++ == 3 ) {
				last;
			}
		}
	};
	if ( $fails == 4 ) {
		do_error( 'SHELLCMD', "Giving up trying to execute command, ABORTING!" );
	}

	my @output = split( /\n/, $output );
	push( @LOGS, $_ ) for @output;
	do_log( 'SHELLCMD', "Done executing, retval = " . ( $retval >> 8 ) );
	return \@output;
}

sub do_build {
	# ignore the args for now, as we use globals :(
	do_log( 'COMPILER', "Preparing to build $stuff{perldist}" );

	# do prebuild stuff
	if ( ! do_prebuild() ) {
		return 0;
	}

	# We start with the standard Configure options
	my $stdoptions = "-des -Dprefix=$C{home}/perls/$stuff{perldist}";

	#=head2 Disabling older versions of Perl
	#
	#Configure will search for binary compatible versions of previously
	#installed perl binaries in the tree that is specified as target tree,
	#and these will be used as locations to search for modules by the perl
	#being built. The list of perl versions found will be put in the Configure
	#variable inc_version_list.
	#
	#To disable this use of older perl modules, even completely valid pure perl
	#modules, you can specify to not include the paths found:
	#
	#sh Configure -Dinc_version_list=none ...
	$stdoptions .= ' -Dinc_version_list=none';

	# Prohibit man/html to be built, saving us time and disk space
	# TODO doesn't work?
#	foreach my $d ( qw( installman1dir installman3dir installhtml1dir installhtml3dir ) ) {
#		$stdoptions .= " -D$d=none";
#	}

	# we start off with the Configure step
	my $extraoptions = '';
	if ( $stuff{perlver} =~ /^5\.(\d+)\./ ) {
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
	if ( defined $stuff{perlopts} ) {
		if ( $stuff{perlopts} =~ /nothr/ ) {
			$extraoptions .= ' -Uusethreads';
		} else {
			$extraoptions .= ' -Dusethreads';
		}

		if ( $stuff{perlopts} =~ /nomulti/ ) {
			$extraoptions .= ' -Uusemultiplicity';
		} else {
			$extraoptions .= ' -Dusemultiplicity';
		}

		if ( $stuff{perlopts} =~ /nolong/ ) {
			$extraoptions .= ' -Uuselongdouble';
		} else {
			$extraoptions .= ' -Duselongdouble';
		}

		if ( $stuff{perlopts} =~ /nomymalloc/ ) {
			$extraoptions .= ' -Uusemymalloc';
		} else {
			$extraoptions .= ' -Dusemymalloc';
		}

		if ( $stuff{perlopts} =~ /64a/ ) {
			$extraoptions .= ' -Duse64bitall';
		} elsif ( $stuff{perlopts} =~ /64i/ ) {
			$extraoptions .= ' -Duse64bitint';
		} elsif ( $stuff{perlopts} =~ /32/ ) {
			$extraoptions .= ' -Uuse64bitall -Uuse64bitint';
		}

		if ( $stuff{perlopts} =~ /noshrplib/ ) {
			$extraoptions .= ' -Uuseshrplib';
		} else {
			$extraoptions .= ' -Duseshrplib';
		}

		if ( $stuff{perlopts} =~ /nodebug/ ) {
			$extraoptions .= ' -DDEBUGGING=none';
		} else {
			$extraoptions .= ' -DDEBUGGING=both';
		}
	}

	# actually do the configure!
	do_shellcommand( "cd $C{home}/build/$stuff{perldist}; sh Configure $stdoptions $extraoptions" );

	# generate dependencies - not needed because Configure -des defaults to automatically doing it
	#do_shellcommand( "cd build/$stuff{perldist}; make depend" );

	# actually compile!
	my $output = do_shellcommand( "cd $C{home}/build/$stuff{perldist}; make" );
	if ( $output->[-1] !~ /to\s+run\s+test\s+suite/ ) {
		# Is it ok to proceed?
		if ( ! check_perl_build( $output ) ) {
			do_log( 'COMPILER', "Unable to compile $stuff{perldist}!" );
			return 0;
		}
	}

	# make sure we pass tests
	$output = do_shellcommand( "cd $C{home}/build/$stuff{perldist}; make test" );
	if ( ! fgrep( '^All\s+tests\s+successful\.$', $output ) ) {
		# Is it ok to proceed?
		if ( ! check_perl_test( $output ) ) {
			do_log( 'COMPILER', "Testsuite failed for $stuff{perldist}!" );
			return 0;
		}
	}

	# okay, do the install!
	do_shellcommand( "cd $C{home}/build/$stuff{perldist}; make install" );

	# all done!
	do_log( 'COMPILER', "Installed $stuff{perldist} successfully!" );
	return 1;
}

# checks for "allowed" build failures ( known problems )
sub check_perl_build {
	my $output = shift;

	# freebsd is wack... throws errors for no idea ( I think, hah! )
	#cp Errno.pm ../../lib/Errno.pm
	#
	#	Everything is up to date. Type 'make test' to run test suite.
	#*** Error code 1 (ignored)
	if ( $^O eq 'freebsd' and $stuff{perlver} =~ /^5\.8\./ and $output->[-1] eq '*** Error code 1 (ignored)' ) {
		do_log( 'COMPILER', "Detected FreeBSD ignored error code 1, ignoring it..." );
		return 1;
	}

	# TODO netbsd has a header problem, but I dunno how to fix it... it's harmless ( I think, hah! )
	#Writing Makefile for Errno
	#../../miniperl "-I../../lib" "-I../../lib" Errno_pm.PL Errno.pm
	#/usr/include/sys/cdefs_elf.h:67:20: error: missing binary operator before token "("
	#cp Errno.pm ../../lib/Errno.pm
	#*** Error code 1
	#        Everything is up to date. Type 'make test' to run test suite.
	# (ignored)
	if ( $^O eq 'netbsd' and $stuff{perlver} =~ /^5\.8\./ and $output->[-1] eq ' (ignored)' ) {
		do_log( 'COMPILER', "Detected NetBSD ignored error code 1, ignoring it..." );
		return 1;
	}

	# Unknown failure!
	return 0;
}

# checks for "allowed" test failures ( known problems )
sub check_perl_test {
	my $output = shift;

	# organize by number of failed tests
	if ( fgrep( '^Failed\s+1\s+test', $output ) ) {
		# TODO argh, file::find often fails, need to track down why it happens
		if ( fgrep( '^lib/File/Find/t/find\.+(?!ok)', $output ) ) {
			do_log( 'COMPILER', "Detected File::Find test failure, ignoring it..." );
			return 1;
		}

		# 5.6.x on netbsd has locale problems...
		#t/pragma/locale........# The following locales
		#
		#       C C ISO8859-0 ISO8859-1 ISO8859-10 ISO8859-11 ISO8859-12
		#...
		#
		# tested okay.
		#
		# The following locales
		#
		#       zh_CN.GB18030
		#
		# had problems.
		#
		#FAILED at test 116
		if ( $^O eq 'netbsd' and $stuff{perlver} =~ /^5\.6\./ and fgrep( 'pragma/locale\.+(?!ok)', $output ) ) {
			do_log( 'COMPILER', "Detected locale test failure on NetBSD for perl-5.6.x, ignoring it..." );
			return 1;
		}

		# TODO 5.8.x < 5.8.9 on freebsd has hostname problems... dunno why
		#lib/Net/t/hostname........................FAILED at test 1
		if ( $^O eq 'freebsd' and $stuff{perlver} =~ /^5\.8\./ and fgrep( '^lib/Net/t/hostname\.+(?!ok)', $output ) ) {
			do_log( 'COMPILER', "Detected hostname test failure on FreeBSD for perl-5.8.x, ignoring it..." );
			return 1;
		}
	} elsif ( fgrep( '^Failed\s+2\s+test', $output ) ) {
		# 5.8.8 has known problems with sprintf.t and sprintf2.t
		#t/op/sprintf..............................FAILED--no leader found
		#t/op/sprintf2.............................FAILED--expected 263 tests, saw 3
		if ( $stuff{perlver} eq '5.8.8' and fgrep( '^t/op/sprintf\.+(?!ok)', $output ) ) {
			do_log( 'COMPILER', "Detected sprintf test failure for perl-5.8.8, ignoring it..." );
			return 1;
		}
	}

	# Unknown failure!
	return 0;
}

# 'fast' grep that returns as soon as a match is found
sub fgrep {
	my( $str, $output ) = @_;
	$str = qr/$str/;
	foreach my $s ( @$output ) {
		if ( $s =~ $str ) {
			return 1;
		}
	}
	return 0;
}

sub do_replacefile {
	my( $file, $data, $quiet ) = @_;
	if ( ! $quiet ) {
		do_log( 'UTILS', "Replacing file '$file' with new data" );
		do_log( "--------------------------------------------------" );
		do_log( $data );
		do_log( "--------------------------------------------------" );
	}

	# for starters, we delete the file
	if ( -f $file ) {
		do_unlink( $file, $quiet );
	}
	open( my $f, '>', $file ) or do_error( 'UTILS', "Unable to open '$file' for writing: $!" );
	print $f $data;
	close( $f ) or do_error( 'UTILS', "Unable to close '$file': $!" );

	return;
}
