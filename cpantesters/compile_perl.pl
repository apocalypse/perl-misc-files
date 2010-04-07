#!/usr/bin/env perl
use strict; use warnings;

# We have successfully compiled those perl versions:
# 5.6.1, 5.6.2
# 5.8.1, 5.8.2, 5.8.3, 5.8.4, 5.8.5, 5.8.6, 5.8.7, 5.8.8, 5.8.9
# 5.10.0, 5.10.1
# 5.11.0, 5.11.1, 5.11.2, 5.11.3, 5.11.4, 5.11.5
# 5.12.0-RC0, 5.12.0-RC1

# We skip 5.6.0 and 5.8.0 because they are problematic builds

# You may see MSWin32 code here but it's untested!

# We have successfully compiled perl on those OSes:
# x86_64/x64/amd64 (64bit) OSes:
#	OpenSolaris 2009.6, FreeBSD 5.2-RELEASE, Ubuntu-server 9.10, NetBSD 5.0.1
# x86 (32bit) OSes:
#

# This compiler builds each perl with a matrix of 49 possible combinations.
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
#	- create "hints" file that sets operating system, 64bit, etc
#		- that way, we can know what perl versions to skip and etc
#		- maybe we can autodetect it?
#		- Sys::Info::Device::CPU::bitness() for a start...
#	- for the patch_hints thing, auto-detect the latest perl tarball and copy it from there instead of hardcoding it here...
#	- fix all TODO lines in this code :)
#	- we should run 2 CPANPLUS configs per perl - "prefer_makefile" true and false...
#	- consider "perl-5.12.0-RC1.tar.gz" and "perl-5.6.1-TRIAL1.tar.gz" devel releases and skip them?
#	- put all our module prereqs into a BEGIN { eval } check so we can pretty-print the missing modules
#	- add $C{perltarball} that tracks the tarball of "current" perl so we can use it in some places instead of manually hunting it...
#	- Use ActiveState perl?
#		- use their binary builds + source build?
#	- Some areas of the code print "\n" but maybe we need a portable way for that? use $/ ?
#	- What is "pager" really for in CPANPLUS config? Can we undef it?

# load our dependencies
use Capture::Tiny qw( tee_merged );
use Prompt::Timeout qw( prompt );
use Sort::Versions qw( versioncmp );
use Sys::Hostname qw( hostname );
use File::Spec;
use File::Path::Tiny;
use File::Which qw( which );
use Term::Title qw( set_titlebar );
use Shell::Command qw( mv );
use File::Find::Rule;

# Global config hash
my %C = (
	'matrix'	=> 0,			# compile the matrix of perl options or not?
	'devel'		=> 0,			# compile the devel versions of perl?
	'home'		=> $ENV{HOME},		# the home path where we do our stuff ( also used for local CPANPLUS config! )
	'cpanp_path'	=> undef,		# the CPANPLUS tarball path we use
	'cpanp_ver'	=> undef,		# the CPANPLUS version we'll use for cpanp-boxed
	'perlver'	=> undef,		# the perl version we're processing now
	'perlopts'	=> undef,		# the perl options we're using for this run
	'perldist'	=> undef,		# the full perl dist ( perl_5.6.2_default or perl_$perlver_$perlopts )
	'server'	=> '192.168.0.200',	# our local CPAN server ( used for mirror/cpantesters upload/etc )
	'serverctport'	=> '11111',		# our local CPAN server CT2.0 socket/httpgateway port
	'serverftpdir'	=> '/CPAN/',		# our local CPAN server ftp dir
	'email'		=> 'apocal@cpan.org'	# the email address to use for CPANPLUS config
);
if ( $^O eq 'MSWin32' ) {
	$C{home} = "C:\\cpansmoke";
}

# Holds our cached logs
my @LOGS = ();

# Set a nice term title
set_titlebar( "Perl-Compiler@" . hostname() );

# Do some basic sanity checks
do_sanity_checks();

# What option do we want to do?
prompt_action();

# TODO doesn't do what I expect... how do I restore the old terminal title?
#set_titlebar( undef );

# all done!
exit;

sub do_sanity_checks {
	# Move to our path!
	chdir( $C{home} ) or die "Unable to chdir($C{home})";

	# First of all, we check to see if our "essential" binaries are present
	my @binaries = qw( perl cpanp lwp-mirror lwp-request );
	if ( $^O eq 'MSWin32' ) {
		push( @binaries, qw( cacls more cmd dmake ) );
	} else {
		push( @binaries, qw( sudo chown make sh patch ) );
	}

	foreach my $bin ( @binaries ) {
		if ( ! length get_binary_path( $bin ) ) {
			die "[SANITYCHECK] The binary '$bin' was not found, please rectify this and re-run this script!";
		}
	}

	# Sanity check strawberry on win32
	if ( $^O eq 'MSWin32' ) {
		if ( $ENV{PATH} =~ /strawberry/ ) {
			die '[SANITYCHECK] Detected Strawberry Perl in $ENV{PATH}, please fix it!';
		}
		if ( -d "C:\\strawberry" ) {
			die "[SANITYCHECK] Detected Old Strawberry Perl in C:\\strawberry, please fix it!";
		}
	}

	# Don't auto-create dirs if we're root
	if ( $< == 0 ) {
		do_log( "[SANITYCHECK] You are running this as root! Be careful in what you do!" );
		my $res = lc( do_prompt( "Do you want us to auto-create the build dirs?", 'n' ) );
		if ( $res eq 'n' ) {
			return;
		}
	}

	# Create some directories we need
	foreach my $dir ( qw( build tmp perls cpanp_conf ) ) {
		my $localdir = File::Spec->catdir( $C{home}, $dir );
		if ( ! -d $localdir ) {
			do_mkdir( $localdir );
		}
	}

	# Do we have the perl tarballs?
	my $path = File::Spec->catdir( $C{home}, 'build' );
	opendir( DIR, $path ) or die "Unable to opendir ($path): $!";
	my @entries = readdir( DIR );
	closedir( DIR ) or die "Unable to closedir ($path): $!";

	# less than 3 entries means only the '.' and '..' entries present..
	# TODO compare number of entries with mirror and get new dists?
	if ( @entries < 3 ) {
		my $res = lc( do_prompt( "Do you want me to automatically get the perl dists?", 'y' ) );
		if ( $res eq 'y' ) {
			downloadPerlTarballs();
		} else {
			do_log( "[SANITYCHECK] No perl dists available..." );
			exit;
		}
	}
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

sub downloadPerlTarballs {
	# Download all the tarballs we see
	do_log( "[SANITYCHECK] Downloading the perl dists..." );

	# TODO hardcoded perl_dists path on ftp?
	my $ftpdir = 'ftp://' . $C{server} . '/perl_dists/';
	if ( $^O eq 'MSWin32' ) {
		$ftpdir .= 'strawberry';
	} else {
		$ftpdir .= 'src';
	}

	my $files = get_directory_contents( $ftpdir );
	foreach my $f ( @$files ) {
		do_log( "[SANITYCHECK] Downloading perl dist '$f'" );

		my $localpath = File::Spec->catfile( $C{home}, 'build', $f );
		if ( -f $localpath ) {
			do_unlink( $localpath );
		}
		do_shellcommand( "lwp-mirror $ftpdir/$f $localpath" );
	}

	return;
}

# this is hackish but it does what we want... hah!
sub get_directory_contents {
	my $url = shift;

	my @files;
	my $output = do_shellcommand( "lwp-request $url" );

#	apoc@blackhole:~$ lwp-request ftp://192.168.0.200/perl_dists/strawberry
#	drwxr-xr-x    2 1001     1002         4096 Dec 19 17:36 bootstrap
#	-rw-r--r--    1 1001     1002     38632105 Jul 29 23:06 strawberry-perl-5.10.0.6.zip
#	-rw-r--r--    1 1001     1002     41407550 Oct 21 16:19 strawberry-perl-5.10.1.0.zip
#	-rw-r--r--    1 1001     1002     34893520 Jan 29  2009 strawberry-perl-5.8.8.4.zip
#	-rw-r--r--    1 1001     1002     40478661 Oct 17 21:44 strawberry-perl-5.8.9.3.zip
	foreach my $l ( @$output ) {
		if ( $l =~ /^\-.+\s+([^\s]+)$/ ) {
			push( @files, $1 );
		}
	}

	return \@files;
}

sub prompt_action {
	my $res;
	while ( ! defined $res ) {
		$res = lc( do_prompt( "What action do you want to do today? [(b)uild/(c)onfigure local cpanp/use (d)evel perl/(e)xit/(i)nstall/too(l)chain update/perl(m)atrix/unchow(n)/(p)rint ready perls/(r)econfig cpanp/(s)ystem toolchain update/perl (t)arballs/(u)ninstall/cho(w)n]", 'e' ) );
		if ( $res eq 'b' ) {
			# prompt user for perl version to compile
			$res = prompt_perlver_tarballs();
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
				do_log( "\t$p" );
			}
		} elsif ( $res eq 's' ) {
			# configure the system for smoking!
			do_config_systemCPANPLUS();
		} elsif ( $res eq 'd' ) {
			# should we use the perl devel versions?
			prompt_develperl();
		} elsif ( $res eq 'l' ) {
			# Update the entire toolchain + Metabase deps
			do_log( "[CPANPLUS] Executing toolchain update on CPANPLUS installs..." );
			iterate_perls( sub {
				if ( do_cpanp_action( $C{perldist}, "s selfupdate all" ) ) {
					do_log( "[CPANPLUS] Successfully updated CPANPLUS on '$C{perldist}'" );

					# Get our toolchain modules
					my $cpanp_action = 'i ' . join( ' ', @{ get_CPANPLUS_toolchain() } );
					if ( do_cpanp_action( $C{perldist}, $cpanp_action ) ) {
						do_log( "[CPANPLUS] Successfully updated toolchain modules on '$C{perldist}'" );
					} else {
						do_log( "[CPANPLUS] Failed to update toolchain modules on '$C{perldist}'" );
					}
				} else {
					do_log( "[CPANPLUS] Failed to update CPANPLUS on '$C{perldist}'" );
				}
			} );
		} elsif ( $res eq 't' ) {
			# Mirror the perl tarballs
			downloadPerlTarballs();
		} elsif ( $res eq 'm' ) {
			# Should we compile/configure/use/etc the perlmatrix?
			prompt_perlmatrix();
		} elsif ( $res eq 'c' ) {
			# configure the local user's CPANPLUS
			do_config_localCPANPLUS();
		} elsif ( $res eq 'i' ) {
			# install a specific module
			my $module = do_prompt( "What module should we install?", '' );
			if ( length $module ) {
				do_log( "[CPANPLUS] Installing '$module' on perls..." );
				iterate_perls( sub {
					if ( do_cpanp_action( $C{perldist}, "i $module" ) ) {
						do_log( "[CPANPLUS] Installed the module on '$C{perldist}'" );
					} else {
						do_log( "[CPANPLUS] Failed to install the module on '$C{perldist}'" );
					}
				} );
			} else {
				do_log( "[CPANPLUS] Module name not specified, please try again." );
			}
		} elsif ( $res eq 'u' ) {
			# uninstall a specific module
			my $module = do_prompt( "What module should we uninstall?", '' );
			if ( length $module ) {
				do_log( "[CPANPLUS] Uninstalling '$module' on all perls..." );
				iterate_perls( sub {
					# use --force so we skip the prompt
					if ( do_cpanp_action( $C{perldist}, "u $module --force" ) ) {
						do_log( "[CPANPLUS] Uninstalled the module from '$C{perldist}'" );
					} else {
						do_log( "[CPANPLUS] Failed to uninstall the module from '$C{perldist}'" );
					}
				} );
			} else {
				do_log( "[CPANPLUS] Module name not specified, please try again." );
			}
		} elsif ( $res eq 'e' ) {
			return;
		} elsif ( $res eq 'w' ) {
			if ( $^O eq 'MSWin32' ) {
				# TODO use cacls.exe or something else?
				do_log( "[COMPILER] Unable to chown on $^O" );
			} else {
				# thanks to BinGOs for the idea to chown the perl installs to prevent rogue modules!
				do_log( "[COMPILER] Executing chown -R root on perl installs..." );
				iterate_perls( sub {
					# some OSes don't have root as a group, so we just set the user
					do_shellcommand( "sudo chown -R root " . File::Spec->catdir( $C{home}, 'perls', $C{perldist} ) );
				} );
			}
		} elsif ( $res eq 'n' ) {
			if ( $^O eq 'MSWin32' ) {
				# TODO use cacls.exe or something else?
				do_log( "[COMPILER] Unable to chown on $^O" );
			} else {
				# Unchown the perl installs so we can do stuff to them :)
				do_log( "[COMPILER] Executing chown -R $< on perl installs..." );
				iterate_perls( sub {
					do_shellcommand( "sudo chown -R $< " . File::Spec->catdir( $C{home}, 'perls', $C{perldist} ) );
				} );
			}
		} elsif ( $res eq 'r' ) {
			# reconfig all perls' CPANPLUS settings
			do_log( "[CPANPLUS] Reconfiguring CPANPLUS instances..." );
			iterate_perls( sub {
				do_installCPANPLUS_config();

				# No longer needed because of CPANIDX
#				if ( do_cpanp_action( $C{perldist}, "x --update_source" ) ) {
#					do_log( "[CPANPLUS] Reconfigured CPANPLUS on '$C{perldist}'" );
#				} else {
#					do_log( "[CPANPLUS] Error in updating sources for '$C{perldist}'" );
#				}
			} );
		} else {
			do_log( "[COMPILER] Unknown action, please try again." );
		}

		# allow the user to run another loop
		$res = undef;
		$C{perlver} = $C{perlopts} = $C{perldist} = undef;
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
			do_log( '[CPANPLUS] Refusing to configure system CPANPLUS without approval...' );
			return 0;
		}
	}

# We let CPANPLUS automatically figure it out!
#	$conf->set_conf( prefer_makefile => 1 );

	# configure the system Config settings
	my $uconfig = <<'END';
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
			'path' => 'XXXCONFIG-SERVERFTPDIRXXX',
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
	do_config_CPANPLUS_actions( $uconfig );

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

	# TODO change config to use CPANIDX?

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

sub iterate_perls {
	my $sub = shift;

	# prompt user for perl version to iterate on
	my $res = prompt_perlver_ready();
	if ( ! defined $res ) {
		do_log( "[ITERATOR] No perls specified, aborting!" );
		return;
	}

	# Get all available perls and iterate over them
	if ( $^O eq 'MSWin32' ) {
		# alternate method, we have to swap perls...
		local $ENV{PATH} = cleanse_strawberry_path();

		foreach my $p ( reverse @$res ) {
			# move this perl to c:\strawberry
			if ( -d "C:\\strawberry" ) {
				die '[ITERATOR] Old strawberry perl found in C:\\strawberry, please fix it!';
			}
			my $perlpath = File::Spec->catdir( $C{home}, 'perls', $p );
			mv( $perlpath, "C:\\strawberry" ) or die "Unable to mv: $!";

			# Okay, set the 3 perl variables we need
			( $C{perlver}, $C{perlopts} ) = split_perl( $p );
			$C{perldist} = $p;

			# execute action
			$sub->();

			# move this perl back to original place
			mv( "C:\\strawberry", $perlpath ) or die "Unable to mv: $!";
		}
	} else {
		# Loop through all versions, starting from newest to oldest
		foreach my $p ( reverse @$res ) {
			# Okay, set the 3 perl variables we need
			( $C{perlver}, $C{perlopts} ) = split_perl( $p );
			$C{perldist} = $p;

			$sub->();
		}
	}

	return;
}

# finds all installed perls that have smoke.ready file in them
sub getReadyPerls {
	my $path = File::Spec->catdir( $C{home}, 'perls' );
	if ( -d $path ) {
		opendir( PERLS, $path ) or die "Unable to opendir ($path): $!";
		my @list = readdir( PERLS );
		closedir( PERLS ) or die "Unable to closedir ($path): $!";

		# find the ready ones
		my %ready = ();
		foreach my $p ( @list ) {
			if ( $p =~ /perl\_/ and -d File::Spec->catdir( $path, $p ) and -e File::Spec->catfile( $path, $p, 'ready.smoke' ) ) {
				# rip out the version
				if ( $p =~ /perl\_([\d\.\w\-]+)\_/ ) {
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

		do_log( "[READYPERLS] Ready Perls: " . scalar @ready );

		return \@ready;
	} else {
		return [];
	}
}

sub prompt_develperl {
	do_log( "[COMPILER] Current devel perl status: " . ( $C{devel} ? 'Y' : 'N' ) );
	my $res = lc( do_prompt( "Compile/use the devel perls?", 'n' ) );
	if ( $res eq 'y' ) {
		$C{devel} = 1;
	} else {
		$C{devel} = 0;
	}

	return;
}

sub prompt_perlmatrix {
	do_log( "[COMPILER] Current matrix perl status: " . ( $C{matrix} ? 'Y' : 'N' ) );
	my $res = lc( do_prompt( "Compile/use the perl matrix?", 'n' ) );
	if ( $res eq 'y' ) {
		$C{matrix} = 1;
	} else {
		$C{matrix} = 0;
	}

	return;
}

sub reset_logs {
	@LOGS = ();
	return;
}

sub save_logs {
	my $end = shift;

	# Dump the logs into the file
	my $file = File::Spec->catfile( $C{home}, 'perls', $C{perldist} . ".$end" );
	do_replacefile( $file, join( "\n", @LOGS ), 1 );

	return;
}

sub do_log {
	my $line = shift;

	print $line . "\n";
	push( @LOGS, $line );
	return;
}

sub get_CPANPLUS_ver {
	# TODO fix hardcoded version - it's nice as a backup but...

	return $C{cpanp_ver} if defined $C{cpanp_ver};

	# TODO argh, win32 needs different quoting schematics!

	# Spawn a shell to find the answer
	my $output = do_shellcommand( $^X . ' -MCPANPLUS::Backend -e \'$cb=CPANPLUS::Backend->new;$mod=$cb->module_tree("CPANPLUS");$ver=defined $mod ? $mod->package_version : undef; print "VER: " . ( defined $ver ? $ver : "UNDEF" ) . "\n";\'' );
	if ( $output->[-1] =~ /^VER\:\s+(.+)$/ ) {
		my $ver = $1;
		if ( $ver ne 'UNDEF' ) {
			$C{cpanp_ver} = $ver;
		}
	}

	# default answer
	$C{cpanp_ver} = '0.9003' if ! defined $C{cpanp_ver};
	return $C{cpanp_ver};

	# Not a good idea, because it consumed gobs of RAM unnecessarily...
#	require CPANPLUS::Backend;
#	my $cb = CPANPLUS::Backend->new;
#	my $mod = $cb->module_tree( "CPANPLUS" );
#	my $ver = defined $mod ? $mod->package_version : undef;
#	if ( defined $ver ) {
#		return $ver;
#	} else {
#		# the default
#		return "0.88";
#	}
}

sub get_CPANPLUS_tarball_path {
	# TODO fix hardcoded path - it's nice as a backup but...

	return $C{cpanp_path} if defined $C{cpanp_path};

	# TODO argh, win32 needs different quoting schematics!

	# Spawn a shell to find the answer
	my $output = do_shellcommand( $^X . ' -MCPANPLUS::Backend -e \'$cb=CPANPLUS::Backend->new;$mod=$cb->module_tree("CPANPLUS");$ver=defined $mod ? $mod->path . "/" . $mod->package : undef; print "TARBALL: " . ( defined $ver ? $ver : "UNDEF" ) . "\n";\'' );
	if ( $output->[-1] =~ /^TARBALL\:\s+(.+)$/ ) {
		my $tar = $1;
		if ( $tar ne 'UNDEF' ) {
			$C{cpanp_path} = $tar;
		}
	}

	# default answer
	$C{cpanp_path} = 'authors/id/B/BI/BINGOS/CPANPLUS-0.9003.tar.gz' if ! defined $C{cpanp_path};
	return $C{cpanp_path};
}

# Look at do_installCPANP_BOXED_config for more details
sub do_config_localCPANPLUS {
	# Not needed for MSWin32?
	if ( $^O eq 'MSWin32' ) {
		my $res = lc( do_prompt( "[CPANPLUS] No need to configure local CPANPLUS on MSWin32. Are you sure?", 'n' ) );
		if ( $res ne 'y' ) {
			return 1;
		}
	}

# We let CPANPLUS automatically figure it out!
#	$conf->set_conf( prefer_makefile => 1 );

# The HTTPGateway solution via POEGateway
#	$conf->set_conf( cpantest_reporter_args => {
#		transport => 'HTTPGateway',
#		transport_args => [ 'http://XXXCONFIG-SERVERXXX:XXXCONFIG-SERVERCTPORTXXX/submit' ],
#	} );

# The CT2.0 Metabase transport
#	$conf->set_conf( cpantest_reporter_args => {
#		transport => 'Metabase',
#		transport_args => [
#			uri => "https://metabase.cpantesters.org/beta/",
#			id_file => "XXXCATDIR-XXXPATHXXX/.metabase/id.jsonXXX",
#		],
#	} );

# We now use CPANIDX to speed up our smoking!
#	$conf->set_conf( source_engine => 'CPANPLUS::Internals::Source::Memory' );

	# configure the local user Config settings
	my $uconfig = <<'END';
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

	### conf section
	$conf->set_conf( allow_build_interactivity => 0 );
	$conf->set_conf( base => 'XXXCATDIR-XXXPATHXXX/.cpanplusXXX' );
	$conf->set_conf( buildflags => 'XXXBUILDFLAGSXXX' );
	$conf->set_conf( cpantest => 1 );
	$conf->set_conf( cpantest_mx => '' );

# The Socket proxied transport, best for my setup - thanks BinGOs!
	$conf->set_conf( cpantest_reporter_args => {
		transport => 'Socket',
		transport_args => [
			host => 'XXXCONFIG-SERVERXXX',
			port => 'XXXCONFIG-SERVERCTPORTXXX',
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
			'path' => 'XXXCONFIG-SERVERFTPDIRXXX',
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
	$conf->set_program( perlwrapper => 'XXXWHICH-cpanp-run-perlXXX' );
	$conf->set_program( shell => 'XXXWHICH-bashXXX' );
	$conf->set_program( sudo => undef );

	return 1;
}
1;
END

	# actually config CPANPLUS!
	do_config_CPANPLUS_actions( $uconfig );

	# blow away any annoying .cpan directories that remain
	my $cpan;
	if ( $^O eq 'MSWin32' ) {
		# TODO is it always in this path?
		# commit: wrote 'C:\Documents and Settings\cpan\Local Settings\Application Data\.cpan\CPAN\MyConfig.pm'
		$cpan = 'C:\\Documents and Settings\\' . $ENV{USERNAME} . '\\Local Settings\\Application Data\\.cpan';
	} else {
		$cpan = File::Spec->catdir( $C{home}, '.cpan' );
	}

	if ( -d $cpan ) {
		do_rmdir( $cpan );
	}

	# thanks to BinGOs for the idea to prevent rogue module installs via CPAN
	do_mkdir( $cpan );
	if ( $^O eq 'MSWin32' ) {
		# TODO use cacls.exe or something?
	} else {
		do_shellcommand( "sudo chown root $cpan" );
	}

	return 1;
}

sub do_config_CPANPLUS_actions {
	my $uconfig = shift;

	# blow away the old cpanplus dir if it's there
	my $cpanplus = File::Spec->catdir( $C{home}, '.cpanplus' );
	if ( -d $cpanplus ) {
		do_rmdir( $cpanplus );
	}

	# overwrite any old config, just in case...
	do_log( "[CPANPLUS] Configuring the CPANPLUS config..." );

	# transform the XXXargsXXX
	$uconfig = do_replacements( $uconfig );

	# save it!
	my $path = File::Spec->catdir( $cpanplus, 'lib', 'CPANPLUS', 'Config' );
	do_mkdir( $path );
	do_replacefile( File::Spec->catfile( $path, 'User.pm' ), $uconfig );

	return 1;
}

sub prompt_perlver_ready {
	return _prompt_perlver( getReadyPerls() );
}

sub prompt_perlver_tarballs {
	return _prompt_perlver( getAvailablePerls() );
}

# prompt the user for perl version
# TODO allow the user to make multiple choices? (m)ultiple option?
sub _prompt_perlver {
	my $perls = shift;

	if ( ! defined $perls or scalar @$perls == 0 ) {
		return undef;
	}

	my $res;
	while ( ! defined $res ) {
		$res = do_prompt( "Which perl version to use? [ver/(d)isplay/(a)ll/(e)xit]", $perls->[-1] );
		if ( lc( $res ) eq 'd' ) {
			# display available versions
			do_log( "[PERLS] Perls[" . ( scalar @$perls ) . "]: " . join( ' ', @$perls ) );
		} elsif ( lc( $res ) eq 'a' ) {
			return $perls;
		} elsif ( lc( $res ) eq 'e' ) {
			return undef;
		} else {
			# make sure the version exists
			if ( ! grep { $_ eq $res } @$perls ) {
				do_log( "[PERLS] The selected version doesn't exist, please try again." );
			} else {
				return [ $res ];
			}
		}

		$res = undef;
	}

	return undef;
}

# cache the @perls array
{
	my $perls = undef;

	# gets the perls
	sub getAvailablePerls {
		return $perls if defined $perls;

		my $path = File::Spec->catdir( $C{home}, 'build' );
		opendir( PERLS, $path ) or die "Unable to opendir ($path): $!";
		$perls = [ sort versioncmp

			# TODO this is a fragile regex
			map { $_ =~ /perl\-([\d\.\w\-]+)\.(?:zip|tar\.(?:gz|bz2))$/; $_ = $1; }
			grep { /perl/ &&
			-f File::Spec->catfile( $path, $_ ) }
			readdir( PERLS )
		];
		closedir( PERLS ) or die "Unable to closedir ($path): $!";

		do_log( "[AVAILABLEPERLS] Available Perls: " . scalar @$perls );

		return $perls;
	}
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
		# TODO use hints to figure out if this is 64bit or 32bit OS
		foreach my $thr ( qw( thr nothr ) ) {
			foreach my $multi ( qw( multi nomulti ) ) {
				foreach my $long ( qw( long nolong ) ) {
					foreach my $malloc ( qw( mymalloc nomymalloc ) ) {
						foreach my $bitness ( qw( 32 64i 64a ) ) {
							if ( ! build_perl_opts( $perl, $thr . '-' . $multi . '-' . $long . '-' . $malloc . '-' . $bitness ) ) {
								save_logs( 'fail' );
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

sub can_build_perl {
	# We skip devel perls if it's not enabled
	if ( $C{perlver} =~ /^5\.(\d+)/ ) {
		if ( $1 % 2 != 0 and ! $C{devel} ) {
			do_log( '[COMPILER] Skipping devel version of perl-' . $C{perlver} . '...' );
			return 0;
		}
	}

	# okay, list the known failures here

	# Skip problematic perls
	if ( $C{perlver} eq '5.6.0' or $C{perlver} eq '5.8.0' ) {
		# CPANPLUS won't work on 5.6.0, also some modules we want to install doesn't like 5.6.x :(
		#
		# <Apocalypse> Yeah wish me luck, last year I managed to get 5.6.0 built but couldn't get CPANPLUS to install on it
		# <Apocalypse> Maybe the situation is better now - I'm working downwards so I'll hit 5.6.X sometime later tonite after I finish 5.8.5, 5.8.4, and so on :)
		# <@kane> 5.6.1 is the minimum
		# <Apocalypse> Ah, so CPANPLUS definitely won't work on 5.6.0? I should just drop it...
		#
		# 5.8.0 blows up horribly in it's tests everywhere I try to compile it...
		do_log( '[COMPILER] Skipping known problematic perl-' . $C{perlver} . '...' );
		return 0;
	}

	# FreeBSD 5.2-RELEASE doesn't like perl-5.6.1 :(
	#
	# cc -c -I../../.. -DHAS_FPSETMASK -DHAS_FLOATINGPOINT_H -fno-strict-aliasing -I/usr/local/include -O    -DVERSION=\"0.10\"  -DXS_VERSION=\"0.10\" -DPIC -fPIC -I../../.. -DSDBM -DDUFF sdbm.c
	# sdbm.c:40: error: conflicting types for 'malloc'
	# sdbm.c:41: error: conflicting types for 'free'
	# /usr/include/stdlib.h:94: error: previous declaration of 'free' was here
	# *** Error code 1
	if ( $^O eq 'freebsd' and $C{perlver} eq '5.6.1' ) {
		do_log( '[COMPILER] Skipping perl-5.6.1 on FreeBSD...' );
		return 0;
	}

	# Analyze the options
	if ( defined $C{perlopts} ) {
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
		if ( ( $^O eq 'netbsd' or $^O eq 'freebsd' ) and $C{perlopts} =~ /(?<!no)long/ ) {
			do_log( '[COMPILER] Skipping -Duselongdouble on NetBSD/FreeBSD...' );
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
		if ( $^O eq 'solaris' and $C{perlver} eq '5.8.7' and $C{perlopts} =~ /64a/ ) {
			do_log( '[COMPILER] Skipping -Duse64bitall on perl-5.8.7 on OpenSolaris' );
			return 0;
		}
	}

	# We can build it!
	return 1;
}

sub install_perl_win32 {
	# Special method to install strawberry perls for win32
	my $perl = shift;

	# Strawberry tacks on an extra digit for it's build number
	if ( $perl =~ /^(\d+\.\d+\.\d+\.\d+)$/ ) {
		$C{perlver} = $perl;
		$C{perlopts} = 'default';
		$C{perldist} = "strawberry_perl_$C{perlver}_$C{perlopts}";
	} else {
		die "[PERLBUILDER] Unknown Strawberry Perl version: $perl";
	}

	# Okay, is this perl installed?
	my $path = File::Spec->catdir( $C{home}, 'perls', $C{perldist} );
	if ( ! -d $path ) {
		# Okay, unzip the archive
		do_archive_extract( File::Spec->catfile( $C{home}, 'build', 'strawberry-perl-' . $C{perlver} . '.zip' ), $path );
	} else {
		# all done with configuring?
		if ( -e File::Spec->catfile( $path, 'ready.smoke' ) ) {
			do_log( "[PERLBUILDER] $C{perldist} is ready to smoke..." );
			return 1;
		} else {
			do_log( "[PERLBUILDER] $C{perldist} is already built..." );
		}
	}

	# move this perl to c:\strawberry
	if ( -d "C:\\strawberry" ) {
		die '[PERLBUILDER] Old Strawberry Perl found in C:\\strawberry, please fix it!';
	}
	mv( $path, "C:\\strawberry" ) or die "Unable to mv: $!";

	my $ret = customize_perl();

	# Move the strawberry install to it's regular place
	mv( "C:\\strawberry", $path ) or die "Unable to mv: $!";

	# finalize the perl install!
	# This needs to be done because customize_perl calls it while the dir is still in c:\strawberry!
	if ( $ret and ! finalize_perl() ) {
		return 0;
	}

	return $ret;
}

sub build_perl_opts {
	# set the perl stuff
	$C{perlver} = shift;
	$C{perlopts} = shift;
	$C{perldist} = "perl_$C{perlver}_$C{perlopts}";

	# Skip problematic perls
	if ( ! can_build_perl() ) {
		return 0;
	}

	# have we already compiled+installed this version?
	my $path = File::Spec->catdir( $C{home}, 'perls', $C{perldist} );
	if ( ! -d $path ) {
		# did the compile fail?
		if ( -e File::Spec->catfile( $C{home}, 'perls', "$C{perldist}.fail" ) ) {
			do_log( "[PERLBUILDER] $C{perldist} already failed, skipping..." );
			return 0;
		}

		# kick off the build process!
		my $ret = do_build();

		# cleanup the build dir ( lots of space! )
		do_rmdir( File::Spec->catdir( $C{home}, 'build', $C{perldist} ) );

		if ( ! $ret ) {
			# failed something during compiling, move on!
			return 0;
		}
	} else {
		# all done with configuring?
		if ( -e File::Spec->catfile( $path, 'ready.smoke' ) ) {
			do_log( "[PERLBUILDER] $C{perldist} is ready to smoke..." );
			return 1;
		} else {
			do_log( "[PERLBUILDER] $C{perldist} is already built..." );
		}
	}

	return customize_perl();
}

sub customize_perl {
	do_log( "[PERLBUILDER] Firing up the $C{perldist} installer..." );

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
	my $path = File::Spec->catdir( $C{home}, 'perls', $C{perldist} );
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
	my $perlver = $C{perlver};
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
	do_log( "[FINALIZER] All done with $C{perldist}..." );
	do_replacefile( File::Spec->catfile( $path, 'ready.smoke' ), join( "\n", @LOGS ) );

	return 1;
}

sub do_prebuild {
	# remove the old dir so we have a consistent build process
	my $build_dir = File::Spec->catdir( $C{home}, 'build', $C{perldist} );
	if ( -d $build_dir ) {
		do_rmdir( $build_dir );
	}

#	[PERLBUILDER] Firing up the perl-5.11.5-default installer...
#	[PERLBUILDER] perl-5.11.5-default is ready to smoke...
#	[PERLBUILDER] Firing up the perl-5.11.4-default installer...
#	[PERLBUILDER] Preparing to build perl-5.11.4-default
#	[EXTRACTOR] Preparing to extract '/export/home/cpan/build/perl-5.11.4.tar.gz'
#	Could not open file '/export/home/cpan/build/perl-5.11.4/AUTHORS': Permission denied at /usr/perl5/site_perl/5.8.4/Archive/Extract.pm line 812
#	Unable to read '/export/home/cpan/build/perl-5.11.4.tar.gz': Could not open file '/export/home/cpan/build/perl-5.11.4/AUTHORS': Permission denied at ./compile.pl line 1072
	# Just remove any old dir that was there ( script exited in the middle so it was not cleaned up )
	my $extract_dir = File::Spec->catdir( $C{home}, 'build', "perl-$C{perlver}" );
	if ( -d $extract_dir ) {
		do_rmdir( $extract_dir );
	}

	# Argh, we need to figure out the tarball - tar.gz or tar.bz2 or what??? ( thanks to perl-5.11.3 which didn't have a tar.gz file heh )
	opendir( PERLDIR, File::Spec->catdir( $C{home}, 'build' ) ) or die "Unable to opendir: $!";
	my @tarballs = grep { /^perl\-$C{perlver}.+/ } readdir( PERLDIR );
	closedir( PERLDIR ) or die "Unable to closedir: $!";
	if ( scalar @tarballs != 1 ) {
		# hmpf!
		do_log( "[PERLBUILDER] Perl tarball for $C{perlver} not found!" );
		return 0;
	}

	# extract the tarball!
	if ( ! do_archive_extract( File::Spec->catfile( $C{home}, 'build', $tarballs[0] ), File::Spec->catdir( $C{home}, 'build' ) ) ) {
		return 0;
	}

	# Move the extracted tarball to our "custom" build dir
	mv( $extract_dir, $build_dir ) or die "Unable to mv: $!";

	# reset the patch counter
	do_patch_reset();

	# now, apply the patches each version needs
	do_prebuild_patches();

	# TODO this sucks, but lib/Benchmark.t usually takes forever and fails unnecessarily on my loaded box...
	# Also, most time-related tests BOMB out because of the dang VM timing semantics...
	my @fails = ( [ 'lib', 'Benchmark.t' ] );
	push( @fails, [ 't', 'op', 'time.t' ], [ 'op', 'time.t' ] );
	push( @fails, [ 'ext', 'Time-HiRes', 't', 'HiRes.t' ] );
	push( @fails, [ 'cpan', 'Time-HiRes', 't', 'HiRes.t' ] );
	push( @fails, [ 't', 'op', 'alarm.t' ], [ 'op', 'alarm.t' ] );

	# TODO fix this freebsd problem on 5.11.3!
	# Failed 4 tests out of 1679, 99.76% okay.
	#	../cpan/Memoize/t/expmod_t.t
	#	../cpan/Time-HiRes/t/HiRes.t
	#	op/alarm.t
	#	op/sselect.t
	if ( $^O eq 'freebsd' ) {
		push( @fails, [ 'lib', 'Memoize', 't', 'expmod_t.t' ] );
		push( @fails, [ 'cpan', 'Memoize', 't', 'expmod_t.t' ] );
		push( @fails, [ 't', 'op', 'sselect.t' ] );
	}

	# remove them!
	my $manipath = File::Spec->catfile( $build_dir, 'MANIFEST' );
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
	my $dir = shift;
	my $quiet = shift;

	do_log( "[COMPILER] Executing rmdir($dir)" ) if ! $quiet;

	File::Path::Tiny::rm( $dir ) or die "Unable to rm '$dir': $!";

	return;
}

sub do_mkdir {
	my $dir = shift;
	my $quiet = shift;

	do_log( "[COMPILER] Executing mkdir($dir)" ) if ! $quiet;

	File::Path::Tiny::mk( $dir ) or die "Unable to mk '$dir': $!";

	return;
}

sub do_unlink {
	my $file = shift;
	my $quiet = shift;

	do_log( "[COMPILER] Executing unlink($file)" ) if ! $quiet;

	unlink( $file ) or die "Unable to unlink '$file': $!";

	return;
}

sub do_initCPANP_BOXED {
	do_log( "[CPANPLUS] Configuring CPANPLUS::Boxed..." );

	# Get the cpanplus data
	get_CPANPLUS_ver();
	get_CPANPLUS_tarball_path();

	# do we have CPANPLUS already extracted?
	my $cpandir = File::Spec->catdir( $C{home}, "CPANPLUS-$C{cpanp_ver}" );
	if ( -d $cpandir ) {
		do_rmdir( $cpandir );
	}

	# do we have the tarball?
	my $cpantarball = File::Spec->catfile( $C{home}, ( File::Spec->splitpath( $C{cpanp_path} ) )[2] );
	if ( ! -f $cpantarball ) {
		# get it!
		do_shellcommand( "lwp-mirror ftp://$C{server}$C{serverftpdir}$C{cpanp_path} $cpantarball" );
	}

	# extract it!
	if ( ! do_archive_extract( $cpantarball, $C{home} ) ) {
		return 0;
	}

	# configure the Boxed.pm file
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

	do_log( "[EXTRACTOR] Preparing to extract '$archive'" );

	require Archive::Extract;
	my $a = Archive::Extract->new( archive => $archive );
	if ( ! defined $a ) {
		do_log( "[EXTRACTOR] Unable to initialize!" );
		return 0;
	}

	if ( defined $path ) {
		if ( ! $a->extract( to => $path ) ) {
			do_log( "[EXTRACTOR] Unable to extract '$archive' to '$path': " . $a->error );
			return 0;
		}
	} else {
		if ( ! $a->extract ) {
			do_log( "[EXTRACTOR] Unable to extract '$archive': " . $a->error );
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
			'path' => 'XXXCONFIG-SERVERFTPDIRXXX',
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
		$cpanp_dir = File::Spec->catdir( $C{home}, "CPANPLUS-$C{cpanp_ver}", '.cpanplus', $ENV{USERNAME}, 'lib', 'CPANPLUS', 'Config' );
	} else {
		$cpanp_dir = File::Spec->catdir( $C{home}, "CPANPLUS-$C{cpanp_ver}", '.cpanplus', $ENV{USER}, 'lib', 'CPANPLUS', 'Config' );
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

	$str =~ s/XXXPERLDISTXXX/$C{perldist}/g;
	$str =~ s/XXXCPANPLUSXXX/$C{cpanp_ver}/g;
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
		die "[CPANPLUS] Unknown config key: $str";
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
	do_log( "[CPANPLUS] Configuring CPANPLUS..." );

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

	# force an update to make sure it's ready for smoking
	# not needed because we use CPANIDX now
#	if ( ! do_cpanp_action( $C{perldist}, "x --update_source" ) ) {
#		return 0;
#	}

	return 1;
}

sub get_CPANPLUS_toolchain {
	# List taken from CPANPLUS::Internals::Constants::Report v0.9003
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
		Test::Harness
		Test::More
	);

	# Add Metabase and our YACSmoke stuff
	push( @toolchain_modules, qw( CPANPLUS::YACSmoke Test::Reporter::Transport::Socket ) );

	# Add our CPANIDX stuff
	#push( @toolchain_modules, qw( CPANPLUS::Internals::Source::CPANIDX ) );

	# TODO wait for BinGOs to release a real version!
	push( @toolchain_modules, qw( B/BI/BINGOS/CPANPLUS-Internals-Source-CPANIDX-0.01_05.tar.gz ) );

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

# The HTTPGateway solution via POEGateway
#	$conf->set_conf( cpantest_reporter_args => {
#		transport => 'HTTPGateway',
#		transport_args => [ 'http://XXXCONFIG-SERVERXXX:XXXCONFIG-SERVERCTPORTXXX/submit' ],
#	} );

# The CT2.0 Metabase transport
#	$conf->set_conf( cpantest_reporter_args => {
#		transport => 'Metabase',
#		transport_args => [
#			uri => "https://metabase.cpantesters.org/beta/",
#			id_file => "XXXCATDIR-XXXPATHXXX/.metabase/id.jsonXXX",
#		],
#	} );

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
			port => 'XXXCONFIG-SERVERCTPORTXXX',
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
			'path' => 'XXXCONFIG-SERVERFTPDIRXXX',
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
	my $oldcpanplus = File::Spec->catdir( $C{home}, 'cpanp_conf', $C{perldist} );
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

		return analyze_cpanp_install( $action, do_shellcommand( "perl " . File::Spec->catfile( $C{home}, "CPANPLUS-$C{cpanp_ver}", 'bin', 'cpanp-boxed' ) . " $action" ) );
	} else {
		return analyze_cpanp_install( $action, do_shellcommand( File::Spec->catfile( $C{home}, 'perls', $C{perldist}, 'bin', 'perl' ) . " " . File::Spec->catfile( $C{home}, "CPANPLUS-$C{cpanp_ver}", 'bin', 'cpanp-boxed' ) . " $action" ) );
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
							do_log( '[CPANPLUS] Detected error while installing modules' );
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
					do_log( '[CPANPLUS] Detected error while indexing' );
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
			do_log( '[CPANPLUS] Detected error while uninstalling modules' );
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
	local $ENV{PERL5_CPANIDX_URL} = 'http://' . $C{server} . ':11110/CPANIDX/';	# TODO fix this hardcoded stuff

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
	do_log( "[SHELLCMD] Executing '$cmd'" );

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
			do_log( "[SHELLCMD] Detected Capture::Tiny FAIL, re-trying command" );

			# ABORT if we fail 3 straight times...
			if ( $fails++ == 3 ) {
				last;
			}
		}
	};
	if ( $fails == 4 ) {
		do_log( "[SHELLCMD] Giving up trying to execute command, ABORTING!" );
		exit;
	}

	my @output = split( /\n/, $output );
	push( @LOGS, $_ ) for @output;
	do_log( "[SHELLCMD] Done executing, retval = " . ( $retval >> 8 ) );
	return \@output;
}

sub do_build {
	# ignore the args for now, as we use globals :(
	do_log( "[PERLBUILDER] Preparing to build $C{perldist}" );

	# do prebuild stuff
	if ( ! do_prebuild() ) {
		return 0;
	}

	# we start off with the Configure step
	my $extraoptions = '';
	if ( $C{perlver} =~ /^5\.(\d+)\./ ) {
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
	if ( defined $C{perlopts} ) {
		if ( $C{perlopts} =~ /nothr/ ) {
			$extraoptions .= ' -Uusethreads';
		} elsif ( $C{perlopts} =~ /thr/ ) {
			$extraoptions .= ' -Dusethreads';
		}

		if ( $C{perlopts} =~ /nomulti/ ) {
			$extraoptions .= ' -Uusemultiplicity';
		} elsif ( $C{perlopts} =~ /multi/ ) {
			$extraoptions .= ' -Dusemultiplicity';
		}

		if ( $C{perlopts} =~ /nolong/ ) {
			$extraoptions .= ' -Uuselongdouble';
		} elsif ( $C{perlopts} =~ /long/ ) {
			$extraoptions .= ' -Duselongdouble';
		}

		if ( $C{perlopts} =~ /nomymalloc/ ) {
			$extraoptions .= ' -Uusemymalloc';
		} elsif ( $C{perlopts} =~ /mymalloc/ ) {
			$extraoptions .= ' -Dusemymalloc';
		}

		if ( $C{perlopts} =~ /64a/ ) {
			$extraoptions .= ' -Duse64bitall';
		} elsif ( $C{perlopts} =~ /64i/ ) {
			$extraoptions .= ' -Duse64bitint';
		} elsif ( $C{perlopts} =~ /32/ ) {
			$extraoptions .= ' -Uuse64bitall -Uuse64bitint';
		}
	}

	# actually do the configure!
	do_shellcommand( "cd $C{home}/build/$C{perldist}; sh Configure -des -Dprefix=$C{home}/perls/$C{perldist} $extraoptions" );

	# generate dependencies - not needed because Configure -des defaults to automatically doing it
	#do_shellcommand( "cd build/$C{perldist}; make depend" );

	# actually compile!
	my $output = do_shellcommand( "cd $C{home}/build/$C{perldist}; make" );
	if ( $output->[-1] !~ /to\s+run\s+test\s+suite/ ) {
		# Is it ok to proceed?
		if ( ! check_perl_build( $output ) ) {
			do_log( "[PERLBUILDER] Unable to compile $C{perldist}!" );
			return 0;
		}
	}

	# make sure we pass tests
	$output = do_shellcommand( "cd $C{home}/build/$C{perldist}; make test" );
	if ( ! fgrep( '^All\s+tests\s+successful\.$', $output ) ) {
		# Is it ok to proceed?
		if ( ! check_perl_test( $output ) ) {
			do_log( "[PERLBUILDER] Testsuite failed for $C{perldist}!" );
			return 0;
		}
	}

	# okay, do the install!
	do_shellcommand( "cd $C{home}/build/$C{perldist}; make install" );

	# all done!
	do_log( "[PERLBUILDER] Installed $C{perldist} successfully!" );
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
	if ( $^O eq 'freebsd' and $C{perlver} =~ /^5\.8\./ and $output->[-1] eq '*** Error code 1 (ignored)' ) {
		do_log( "[PERLBUILDER] Detected FreeBSD ignored error code 1, ignoring it..." );
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
	if ( $^O eq 'netbsd' and $C{perlver} =~ /^5\.8\./ and $output->[-1] eq ' (ignored)' ) {
		do_log( "[PERLBUILDER] Detected NetBSD ignored error code 1, ignoring it..." );
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
			do_log( "[PERLBUILDER] Detected File::Find test failure, ignoring it..." );
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
		if ( $^O eq 'netbsd' and $C{perlver} =~ /^5\.6\./ and fgrep( 'pragma/locale\.+(?!ok)', $output ) ) {
			do_log( "[PERLBUILDER] Detected locale test failure on NetBSD for perl-5.6.x, ignoring it..." );
			return 1;
		}

		# TODO 5.8.x < 5.8.9 on freebsd has hostname problems... dunno why
		#lib/Net/t/hostname........................FAILED at test 1
		if ( $^O eq 'freebsd' and $C{perlver} =~ /^5\.8\./ and fgrep( '^lib/Net/t/hostname\.+(?!ok)', $output ) ) {
			do_log( "[PERLBUILDER] Detected hostname test failure on FreeBSD for perl-5.8.x, ignoring it..." );
			return 1;
		}
	} elsif ( fgrep( '^Failed\s+2\s+test', $output ) ) {
		# 5.8.8 has known problems with sprintf.t and sprintf2.t
		#t/op/sprintf..............................FAILED--no leader found
		#t/op/sprintf2.............................FAILED--expected 263 tests, saw 3
		if ( $C{perlver} eq '5.8.8' and fgrep( '^t/op/sprintf\.+(?!ok)', $output ) ) {
			do_log( "[PERLBUILDER] Detected sprintf test failure for perl-5.8.8, ignoring it..." );
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

sub do_prebuild_patches {
	# okay, what version is this?
	if ( $C{perlver} =~ /^5\.8\.(\d+)$/ ) {
		my $v = $1;
		if ( $v == 0 or $v == 1 or $v == 2 or $v == 3 or $v == 4 or $v == 5 or $v == 6 or $v == 7 or $v == 8 ) {
			# fix asm/page.h error
			patch_asmpageh();

			patch_makedepend_escape();

			patch_makedepend_cleanups_58x();
		}
	} elsif ( $C{perlver} =~ /^5\.6\.(\d+)$/ ) {
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
		my $patchfile = File::Spec->catfile( $C{home}, 'build', $C{perldist}, "patch.$patch_num" );
		do_replacefile( $patchfile, $patchdata );
		do_shellcommand( "patch -p0 -d " . File::Spec->catdir( $C{home}, 'build', $C{perldist} ) . " < $patchfile" );
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

	# load the hints/netbsd.sh from perl-5.12.0-RC1
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
    *)	cat >&4 <<EOF
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
	do_replacefile( File::Spec->catfile( $C{home}, 'build', $C{perldist}, 'hints', 'netbsd.sh' ), $data );

	return;
}

sub patch_hints_freebsd {
	# same strategy as netbsd, we need it...

	# load the hints/freebsd.sh from perl-5.12.0-RC1
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

	do_replacefile( File::Spec->catfile( $C{home}, 'build', $C{perldist}, 'hints', 'freebsd.sh' ), $data );

	return;
}

sub do_replacefile {
	my( $file, $data, $quiet ) = @_;
	if ( ! $quiet ) {
		do_log( "[COMPILER] Replacing file '$file' with new data" );
		do_log( "--------------------------------------------------" );
		do_log( $data );
		do_log( "--------------------------------------------------" );
	}

	# for starters, we delete the file
	if ( -f $file ) {
		do_unlink( $file, $quiet );
	}
	open( my $f, '>', $file ) or die "Unable to open '$file' for writing: $!";
	print $f $data;
	close( $f ) or die "Unable to close '$file': $!";

	return;
}
