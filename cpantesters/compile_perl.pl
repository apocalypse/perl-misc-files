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
# /home/cpan/build/perl-5.6.2-thr-32		<-- one extracted perl build
# /home/cpan/perls				<-- the perl installation directory
# /home/cpan/perls/perl-5.6.2-thr-32		<-- finalized perl install
# /home/cpan/cpanp_conf				<-- where we store the CPANPLUS configs
# /home/cpan/cpanp_conf/perl-5.6.2-thr-32	<-- CPANPLUS config location for a specific perl
# /home/cpan/compile_perl.pl			<-- where this script should be

# this script does everything, but we need some layout to be specified ( this is the win32 variant )
# c:\cpansmoke						<-- the main directory
# c:\cpansmoke\tmp					<-- tmp directory for cpan/perl/etc cruft
# c:\cpansmoke\build					<-- where we store our perl builds + zips
# c:\cpansmoke\build\strawberry-perl-5.8.9.3.zip	<-- one perl zip
# c:\cpansmoke\perls					<-- the perl installation directory
# c:\cpansmoke\perls\strawberry-perl-5.8.9		<-- finalized perl install
# c:\cpansmoke\cpanp_conf				<-- where we store the CPANPLUS configs
# c:\cpansmoke\cpanp_conf\strawberry-perl-5.8.9		<-- CPANPLUS config location for a specific perl
# c:\cpansmoke\compile_perl.pl				<-- where this script should be

# TODO LIST
#	- create "hints" file that sets operating system, 64bit, etc
#		- that way, we can know what perl versions to skip and etc
#		- maybe we can autodetect it?
#		- Sys::Info::Device::CPU::bitness() for a start...
#	- auto-config the root/system CPANPLUS?
#	- for the patch_hints thing, auto-detect the latest perl tarball and copy it from there instead of hardcoding it here...
#	- move hardcoded stuff into variables - something like %CONFIG
#	- fix all TODO lines in this code :)
#	- we should run 2 CPANPLUS configs per perl - "prefer_makefile" true and false...
#	- ARGH, perl-5.12.0-RC0.tar.gz screws up with our version system and everything...
#		- for now I just move it to perl-5.12.0.tar.gz because it's too much yak shaving to fix the system :(

# load our dependencies
use Capture::Tiny qw( tee_merged );
use Prompt::Timeout;
use Sort::Versions;
use Sys::Hostname qw( hostname );
use File::Spec;
use File::Path::Tiny;
use File::Which qw( which );
use Term::Title qw( set_titlebar );
use Shell::Command qw( mv );

# static var...
my $perlver;		# the perl version we're processing now
my $perlopts;		# the perl options we're using for this run
my $CPANPLUS_ver;	# the CPANPLUS version we'll use for cpanp-boxed
my $CPANPLUS_path;	# the CPANPLUS tarball path we use
my @LOGS = ();		# holds stored logs for a run
my $domatrix = 0;	# compile the matrix of perl options or not?
my $dodevel = 0;	# compile the devel versions of perl?
my $PATH;		# the home path where we do our stuff ( also used for local CPANPLUS config! )
if ( $^O eq 'MSWin32' ) {
	$PATH = "C:\\cpansmoke";
} else {
	$PATH = $ENV{HOME};
}

# Global config hash
my %C = (
	'matrix'	=> $domatrix,		# compile the matrix of perl options or not?
	'devel'		=> $dodevel,		# compile the devel versions of perl?
	'path'		=> $PATH,		# the home path where we do our stuff ( also used for local CPANPLUS config! )
	'cpanp_path'	=> $CPANPLUS_path,	# the CPANPLUS tarball path we use
	'cpanp_ver'	=> $CPANPLUS_ver,	# the CPANPLUS version we'll use for cpanp-boxed
	'perlver'	=> $perlver,		# the perl version we're processing now
	'perlopts'	=> $perlopts,		# the perl options we're using for this run
	'dist'		=> undef,		# the full perl dist
	'server'	=> '192.168.0.200'	# our local CPAN server ( used for mirror/cpantesters upload/etc )
);

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
	chdir( $C{path} ) or die "Unable to chdir($C{path})";

	# First of all, we check to see if our "essential" binaries are present
	my @binaries = qw( perl cpanp lwp-mirror lwp-request );
	if ( $^O eq 'MSWin32' ) {
		push( @binaries, qw( cacls more cmd dmake ) );
	} else {
		push( @binaries, qw( sudo chown make sh patch ) );
	}

	foreach my $bin ( @binaries ) {
		if ( ! length get_binary_path( $bin ) ) {
			die "ERROR: The binary '$bin' was not found, please rectify this and re-run this script!\n";
		}
	}

	# Create some directories we need
	foreach my $dir ( qw( build tmp perls cpanp_conf ) ) {
		my $localdir = File::Spec->catdir( $C{path}, $dir );
		if ( ! -d $localdir ) {
			do_log( "[SANITYCHECK] Executing mkdir($localdir)" );
			mkdir( $localdir ) or die "Unable to mkdir ($localdir): $!";
		}
	}

	# Do we have the perl tarballs?
	my $path = File::Spec->catdir( $C{path}, 'build' );
	opendir( DIR, $path ) or die "Unable to opendir ($path): $!";
	my @entries = readdir( DIR );
	closedir( DIR ) or die "Unable to closedir ($path): $!";

	# less than 3 entries means only the '.' and '..' entries present..
	if ( @entries < 3 ) {
		my $res = lc( prompt( "Do you want me to automatically get the perl dists", 'y', 120 ) );
		if ( $res eq 'y' ) {
			getPerlTarballs();
		} else {
			do_log( "[SANITYCHECK] No perl dists available..." );
			exit;
		}
	}
}

sub getPerlTarballs {
	# Download all the tarballs we see
	do_log( "[SANITYCHECK] Downloading the perl dists..." );

	my $ftpdir = 'ftp://' . $C{server} . '/perl_dists/';
	if ( $^O eq 'MSWin32' ) {
		$ftpdir .= 'strawberry';
	} else {
		$ftpdir .= 'src';
	}

	my $files = get_directory_contents( $ftpdir );
	foreach my $f ( @$files ) {
		do_log( "[SANITYCHECK] Downloading perl dist '$f'" );

		my $localpath = File::Spec->catfile( $C{path}, 'build', $f );
		if ( -f $localpath ) {
			unlink( $localpath ) or die "Unable to unlink ($localpath): $!";
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
		$res = lc( prompt( "What action do you want to do today? [(b)uild/(c)onfigure local cpanp/use (d)evel perl/(e)xit/(i)nstall/too(l)chain update/perl(m)atrix/unchow(n)/(r)econfig cpanp/perl (t)arballs/(u)ninstall/cho(w)n/inde(x)]", 'e', 120 ) );
		if ( $res eq 'b' ) {
			# prompt user for perl version to compile
			$res = prompt_perlver( 0 );
			if ( defined $res ) {
				if ( $res ne 'a' ) {
					# do the stuff!
					install_perl( $res );
				} else {
					# loop through all versions, starting from newest to oldest
					foreach my $p ( reverse @{ getPerlVersions() } ) {
						install_perl( $p );
					}
				}
			}
		} elsif ( $res eq 'd' ) {
			# should we use the perl devel versions?
			prompt_develperl();
		} elsif ( $res eq 'l' ) {
			# Update the entire toolchain + Metabase deps
			do_log( "[CPANPLUS] Executing toolchain update on CPANPLUS installs..." );
			iterate_perls( sub {
				my $p = shift;

				if ( do_cpanp_action( $p, "s selfupdate all" ) ) {
					do_log( "[CPANPLUS] Successfully updated CPANPLUS on '$p'" );

					# Get our toolchain modules
					my $cpanp_action = 'i ' . join( ' ', @{ get_CPANPLUS_toolchain() } );
					if ( do_cpanp_action( $p, $cpanp_action ) ) {
						do_log( "[CPANPLUS] Successfully updated toolchain modules on '$p'" );
					} else {
						do_log( "[CPANPLUS] Failed to update toolchain modules on '$p'" );
					}
				} else {
					do_log( "[CPANPLUS] Failed to update CPANPLUS on '$p'" );
				}
			} );
		} elsif ( $res eq 't' ) {
			# Mirror the perl tarballs
			getPerlTarballs();
		} elsif ( $res eq 'm' ) {
			# Should we compile/configure/use/etc the perlmatrix?
			prompt_perlmatrix();
		} elsif ( $res eq 'c' ) {
			# configure the local user's CPANPLUS
			do_config_localCPANPLUS();
		} elsif ( $res eq 'x' ) {
			# update the local user's CPANPLUS index ( the one we share with all perls )
			do_log( "[CPANPLUS] Updating local CPANPLUS index..." );
			local $ENV{APPDATA} = $C{path};
			do_shellcommand( "cpanp x --update_source" );
		} elsif ( $res eq 'i' ) {
			# install a specific module
			my $module = prompt( "What module should we install?", '', 120 );
			if ( defined $module and length $module ) {
				do_log( "[CPANPLUS] Installing '$module' on perls..." );
				iterate_perls( sub {
					my $p = shift;

					if ( do_cpanp_action( $p, "i $module" ) ) {
						do_log( "[CPANPLUS] Installed the module on '$p'" );
					} else {
						do_log( "[CPANPLUS] Failed to install the module on '$p'" );
					}
				} );
			} else {
				do_log( "[CPANPLUS] Module name not specified, please try again." );
			}
		} elsif ( $res eq 'u' ) {
			# uninstall a specific module
			my $module = prompt( "What module should we uninstall?", '', 120 );
			if ( defined $module and length $module ) {
				do_log( "[CPANPLUS] Uninstalling '$module' on all perls..." );
				iterate_perls( sub {
					my $p = shift;

					# use --force so we skip the prompt
					if ( do_cpanp_action( $p, "u $module --force" ) ) {
						do_log( "[CPANPLUS] Uninstalled the module from '$p'" );
					} else {
						do_log( "[CPANPLUS] Failed to uninstall the module from '$p'" );
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
					my $p = shift;

					# some OSes don't have root as a group, so we just set the user
					do_shellcommand( "sudo chown -R root " . File::Spec->catdir( $C{path}, 'perls', $p ) );
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
					my $p = shift;

					do_shellcommand( "sudo chown -R $< " . File::Spec->catdir( $C{path}, 'perls', $p ) );
				} );
			}
		} elsif ( $res eq 'r' ) {
			# reconfig all perls' CPANPLUS settings
			do_log( "[CPANPLUS] Reconfiguring+reindexing CPANPLUS instances..." );
			iterate_perls( sub {
				my $p = shift;

				# get the perlver/perlopts
				if ( $p =~ /^perl-([\d\.]+)-(.+)$/ ) {
					( $perlver, $perlopts ) = ( $1, $2 );
					do_installCPANPLUS_config();
					if ( do_cpanp_action( "perl-$perlver-$perlopts", "x --update_source" ) ) {
						do_log( "[CPANPLUS] Reconfigured perl-$perlver-$perlopts" );
					} else {
						do_log( "[CPANPLUS] Error in updating sources for perl-$perlver-$perlopts" );
					}
				}
			} );
		} else {
			do_log( "[COMPILER] Unknown action, please try again." );
		}

		# allow the user to run another loop
		$res = undef;
		$perlver = undef;
		$perlopts = undef;
		reset_logs();
	}

	return;
}

sub iterate_perls {
	my $sub = shift;

	# prompt user for perl version to iterate on
	my $res = prompt_perlver( 1 );
	if ( ! defined $res ) {
		do_log( "[ITERATOR] No perls specified, aborting!" );
		return;
	}

	# Get all available perls and iterate over them
	if ( $^O eq 'MSWin32' ) {
		# TODO use the $res perls

		# alternate method, we have to swap perls...
		local $ENV{PATH} = cleanse_strawberry_path();
		foreach my $p ( @{ getReadyPerls() } ) {
			# move this perl to c:\strawberry
			if ( -d "C:\\strawberry" ) {
				die "Old strawberry perl found in C:\\strawberry, please fix it!";
			}
			my $perlpath = File::Spec->catdir( $C{path}, 'perls', $p );
			mv( $perlpath, "C:\\strawberry" ) or die "Unable to mv: $!";

			# execute action
			$sub->( $p );

			# move this perl back to original place
			mv( "C:\\strawberry", $perlpath ) or die "Unable to mv: $!";
		}
	} else {
		if ( $res ne 'a' ) {
			# Only run on this perl!
			$sub->( $res );
		} else {
			# loop through all versions, starting from newest to oldest
			foreach my $p ( reverse @{ getReadyPerls() } ) {
				$sub->( $p );
			}
		}
	}

	return;
}

# finds all installed perls that have smoke.ready file in them
sub getReadyPerls {
	my $path = File::Spec->catdir( $C{path}, 'perls' );
	if ( -d $path ) {
		opendir( PERLS, $path ) or die "Unable to opendir ($path): $!";
		my @list = readdir( PERLS );
		closedir( PERLS ) or die "Unable to closedir ($path): $!";

		# find the ready ones
		my %ready = ();
		foreach my $p ( @list ) {
			if ( $p =~ /^perl\-/ and -d File::Spec->catdir( $path, $p ) and -e File::Spec->catfile( $path, $p, 'ready.smoke' ) ) {
				# rip out the version
				if ( $domatrix ) {
					if ( $p =~ /^perl\-([\d\.]+)\-/ ) {
						push( @{ $ready{ $1 } }, $p );
					}
				} else {
					if ( $p =~ /^perl\-([\d\.]+)\-default/ ) {
						push( @{ $ready{ $1 } }, $p );
					}
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

		do_log( "[READYPERLS] Found " . ( scalar @ready ) . " perls ready to use" );
		return \@ready;
	} else {
		do_log( "[READYPERLS] No perl distribution is built yet..." );
		return [];
	}
}

sub prompt_develperl {
	my $res = lc( prompt( "Compile/use the devel perls", 'n', 120 ) );
	if ( $res eq 'y' ) {
		$dodevel = 1;
		$C{devel} = 1;
	} else {
		$dodevel = 0;
		$C{devel} = 0;
	}

	return;
}

sub prompt_perlmatrix {
	my $res = lc( prompt( "Compile/use the perl matrix", 'n', 120 ) );
	if ( $res eq 'y' ) {
		$domatrix = 1;
		$C{matrix} = 1;
	} else {
		$domatrix = 0;
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

	# Make sure we don't overwrite logs
	my $file = File::Spec->catfile( $C{path}, 'perls', "perl-$perlver-$perlopts.$end" );
	if ( -e $file ) {
#		print "[LOGS] Skipping log save of '$file' as it already exists\n";
	} else {
		print "[LOGS] Saving log to '$file'\n";
		open( my $log, '>', $file ) or die "Unable to create log ($file): $!";
		foreach my $l ( @LOGS ) {
			print $log "$l\n";
		}
		close( $log ) or die "Unable to close log ($file): $!";
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
	# TODO fix hardcoded version - it's nice as a backup but...

	# Spawn a shell to find the answer
	my $output = do_shellcommand( $^X . ' -MCPANPLUS::Backend -e \'$cb=CPANPLUS::Backend->new;$mod=$cb->module_tree("CPANPLUS");$ver=defined $mod ? $mod->package_version : undef; print "VER: " . ( defined $ver ? $ver : "UNDEF" ) . "\n";\'' );
	if ( $output->[-1] =~ /^VER\:\s+(.+)$/ ) {
		my $ver = $1;
		if ( $ver ne 'UNDEF' ) {
			return $ver;
		}
	}

	# default answer
	return '0.9003';

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

	# Spawn a shell to find the answer
	my $output = do_shellcommand( $^X . ' -MCPANPLUS::Backend -e \'$cb=CPANPLUS::Backend->new;$mod=$cb->module_tree("CPANPLUS");$ver=defined $mod ? $mod->path . "/" . $mod->package : undef; print "TARBALL: " . ( defined $ver ? $ver : "UNDEF" ) . "\n";\'' );
	if ( $output->[-1] =~ /^TARBALL\:\s+(.+)$/ ) {
		my $tar = $1;
		if ( $tar ne 'UNDEF' ) {
			return $tar;
		}
	}

	# default answer
	return 'authors/id/B/BI/BINGOS/CPANPLUS-0.9003.tar.gz';
}

# Look at do_installCPANP_BOXED_config for more details
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
	$conf->set_conf( base => 'XXXCATDIR-XXXPATHXXX/.cpanplusXXX' );
	$conf->set_conf( buildflags => 'uninst=1' );
	$conf->set_conf( cpantest => 1 );
	$conf->set_conf( cpantest_mx => '' );
#	$conf->set_conf( cpantest_reporter_args => {
#		transport => 'HTTPGateway',
#		transport_args => [ 'http://192.168.0.200:11111/submit' ],
#	} );

#	$conf->set_conf( cpantest_reporter_args => {
#		transport => 'Metabase',
#		transport_args => [
#			uri => "https://metabase.cpantesters.org/beta/",
#			id_file => "XXXCATDIR-XXXPATHXXX/.metabase/id.jsonXXX",
#		],
#	} );

	$conf->set_conf( cpantest_reporter_args => {
		transport => 'Socket',
		transport_args => [
			host => '192.168.0.200',
			port => 11_111,
		],
	} );

	$conf->set_conf( debug => 0 );
	$conf->set_conf( dist_type => '' );
	$conf->set_conf( email => 'apocal@cpan.org' );
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
	$conf->set_conf( makeflags => 'UNINST=1' );
	$conf->set_conf( makemakerflags => '' );
	$conf->set_conf( md5 => 1 );
	$conf->set_conf( no_update => 1 );
	$conf->set_conf( passive => 1 );
	$conf->set_conf( prefer_bin => 1 );

# We let CPANPLUS automatically figure it out!
#	$conf->set_conf( prefer_makefile => 1 );

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

	# blow away the old cpanplus dir if it's there
	my $cpanplus = File::Spec->catdir( $C{path}, '.cpanplus' );
	if ( -d $cpanplus ) {
		do_log( "[CPANPLUS] Removing old CPANPLUS conf directory in '$cpanplus'" );
		File::Path::Tiny::rm( $cpanplus ) or die "Unable to rm ($cpanplus): $!";
	}

	# overwrite any old config, just in case...
	do_log( "[CPANPLUS] Configuring the local user's CPANPLUS config..." );

	# transform the XXXargsXXX
	$uconfig = do_replacements( $uconfig );

	# save it!
	my $path = File::Spec->catdir( $cpanplus, 'lib', 'CPANPLUS', 'Config' );
	File::Path::Tiny::mk( $path ) or die "Unable to mk ($path): $!";
	$path = File::Spec->catfile( $path, 'User.pm' );
	open( my $config, '>', $path ) or die "Unable to create config ($path): $!";
	print $config $uconfig;
	close( $config ) or die "Unable to close config ($path): $!";

	# force an update
	# we don't use do_cpanp_action() here because we need to use the local user's CPANPLUS config not the perl's one...
	{
		local $ENV{APPDATA} = $C{path};
		do_shellcommand( "cpanp x --update_source" );
	}

	# blow away any annoying .cpan directories that remain
	my $cpan;
	if ( $^O eq 'MSWin32' ) {
		# commit: wrote 'C:\Documents and Settings\cpan\Local Settings\Application Data\.cpan\CPAN\MyConfig.pm'
		$cpan = 'C:\\Documents and Settings\\' . $ENV{USERNAME} . '\\Local Settings\\Application Data\\.cpan';
	} else {
		$cpan = File::Spec->catdir( $C{path}, '.cpan' );
	}

	if ( -d $cpan ) {
		do_log( "[CPANPLUS] Sanitizing the '$cpan' directory..." );
		File::Path::Tiny::rm( $cpan ) or die "Unable to rm ($cpan): $!";
	}

	# thanks to BinGOs for the idea to prevent rogue module installs via CPAN
	do_log( "[CPANPLUS] Executing mkdir($cpan)" );
	mkdir( $cpan ) or die "Unable to mkdir ($cpan): $!";
	if ( $^O eq 'MSWin32' ) {
		# TODO use cacls.exe or something?
	} else {
		do_shellcommand( "sudo chown root $cpan" );
	}

	return;
}

# prompt the user for perl version
sub prompt_perlver {
	# Should we look at tarballs or at ready perls?
	my $do_ready = shift;

	my $perls;
	if ( $do_ready ) {
		$perls = getReadyPerls();
	} else {
		$perls = getPerlVersions();
	}

	my $res;
	while ( ! defined $res ) {
		$res = lc( prompt( "Which perl version to use [ver/(d)isplay/(a)ll/(e)xit]", $perls->[-1], 120 ) );
		if ( $res eq 'd' ) {
			# display available versions
			do_log( "[READYPERLS] Available Perls[" . ( scalar @$perls ) . "]: " . join( ' ', @$perls ) );
		} elsif ( $res eq 'a' ) {
			return 'a';
		} elsif ( $res eq 'e' ) {
			return undef;
		} else {
			# make sure the version exists
			if ( ! grep { $_ eq $res } @$perls ) {
				do_log( "[READYPERLS] Selected version doesn't exist, please try again." );
			} else {
				return $res;
			}
		}

		$res = undef;
	}

	return;
}

# cache the @perls array
{
	my $perls = undef;

	# gets the perls
	sub getPerlVersions {
		return $perls if defined $perls;

		my $path = File::Spec->catdir( $C{path}, 'build' );
		opendir( PERLS, $path ) or die "Unable to opendir ($path): $!";
		$perls = [ sort versioncmp map { $_ =~ /^perl\-([\d\.]+)\./; $_ = $1; } grep { /^perl\-[\d\.]+\.(?:zip|tar\.(?:gz|bz2))$/ && -f File::Spec->catfile( $path, $_ ) } readdir( PERLS ) ];
		closedir( PERLS ) or die "Unable to closedir ($path): $!";

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

	# Skip problematic perls
	if ( ! can_build_perl( $perl, undef ) ) {
		do_log( "[PERLBUILDER] Skipping perl-$perl because of known problems..." );
		return;
	}

	# build a default build
	if ( ! build_perl_opts( $perl, 'default' ) ) {
		save_logs( 'fail' );
	} else {
#		save_logs( 'ok' );
	}
	reset_logs();

	# Should we also compile the matrix?
	if ( $domatrix ) {
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

sub can_build_perl {
	my( $p, $o ) = @_;

	# We skip devel perls if it's not enabled
	if ( $p =~ /^5\.(\d+)/ ) {
		if ( $1 % 2 != 0 and ! $C{devel} ) {
			return 0;
		}
	}

	# okay, list the known failures here

	# Skip problematic perls
	if ( $p eq '5.6.0' or $p eq '5.8.0' ) {
		# CPANPLUS won't work on 5.6.0, also some modules we want to install doesn't like 5.6.x :(
		#
		# <Apocalypse> Yeah wish me luck, last year I managed to get 5.6.0 built but couldn't get CPANPLUS to install on it
		# <Apocalypse> Maybe the situation is better now - I'm working downwards so I'll hit 5.6.X sometime later tonite after I finish 5.8.5, 5.8.4, and so on :)
		# <@kane> 5.6.1 is the minimum
		# <Apocalypse> Ah, so CPANPLUS definitely won't work on 5.6.0? I should just drop it...
		#
		# 5.8.0 blows up horribly in it's tests everywhere I try to compile it...
		return 0;
	}

	# FreeBSD 5.2-RELEASE doesn't like perl-5.6.1 :(
	#
	# cc -c -I../../.. -DHAS_FPSETMASK -DHAS_FLOATINGPOINT_H -fno-strict-aliasing -I/usr/local/include -O    -DVERSION=\"0.10\"  -DXS_VERSION=\"0.10\" -DPIC -fPIC -I../../.. -DSDBM -DDUFF sdbm.c
	# sdbm.c:40: error: conflicting types for 'malloc'
	# sdbm.c:41: error: conflicting types for 'free'
	# /usr/include/stdlib.h:94: error: previous declaration of 'free' was here
	# *** Error code 1
	if ( $^O eq 'freebsd' and $p eq '5.6.1' ) {
		return 0;
	}

	# Analyze the options
	if ( defined $o ) {
		# NetBSD 5.0.1 cannot build -Duselongdouble:
		#
		# *** You requested the use of long doubles but you do not seem to have
		# *** the following mathematical functions needed for long double support:
		# ***     sqrtl modfl frexpl
		# *** Please rerun Configure without -Duselongdouble and/or -Dusemorebits.
		# *** Cannot continue, aborting.
		if ( $^O eq 'netbsd' and $o =~ /(?<!no)long/ ) {
			return 0;
		}

		# FreeBSD 5.2-RELEASE cannot build -Duselongdouble:
		#
		# *** You requested the use of long doubles but you do not seem to have
		# *** the following mathematical functions needed for long double support:
		# ***     sqrtl
		# *** Please rerun Configure without -Duselongdouble and/or -Dusemorebits.
		# *** Cannot continue, aborting.
		if ( $^O eq 'freebsd' and $o =~ /(?<!no)long/ ) {
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
		if ( $^O eq 'solaris' and $p eq '5.8.7' and $o =~ /64a/ ) {
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
	if ( $perl =~ /^(\d+\.\d+\.\d+)\.\d+$/ ) {
		$perlver = $1;
		$perlopts = 'default';
	} else {
		die "Unknown strawberry perl version: $perl";
	}

	# Okay, is this perl installed?
	my $path = File::Spec->catdir( $PATH, 'perls', "perl-$perlver-$perlopts" );
	if ( ! -d $path ) {
		# TODO Okay, unzip the archive
	} else {
		# all done with configuring?
		if ( -e File::Spec->catfile( $path, 'ready.smoke' ) ) {
			do_log( "[PERLBUILDER] perl-$perlver-$perlopts is ready to smoke..." );
			return 1;
		} else {
			do_log( "[PERLBUILDER] perl-$perlver-$perlopts is already built..." );
		}
	}

	# move this perl to c:\strawberry
	if ( -d "C:\\strawberry" ) {
		die "Old strawberry perl found in C:\\strawberry, please fix it!";
	}
	mv( $path, "C:\\strawberry" ) or die "Unable to mv: $!";

	my $ret = customize_perl();

	# Move the strawberry install to it's regular place
	mv( "C:\\strawberry", $path ) or die "Unable to mv: $!";

	return $ret;
}

sub build_perl_opts {
	# set the perl stuff
	( $perlver, $perlopts ) = @_;

	# have we already compiled+installed this version?
	my $path = File::Spec->catdir( $PATH, 'perls', "perl-$perlver-$perlopts" );
	if ( ! -d $path ) {
		# did the compile fail?
		if ( -e File::Spec->catfile( $PATH, 'perls', "perl-$perlver-$perlopts.fail" ) ) {
			do_log( "[PERLBUILDER] perl-$perlver-$perlopts already failed, skipping..." );
			return 0;
		}

		# Can we even build this combination?
		if ( ! can_build_perl( $perlver, $perlopts ) ) {
			do_log( "[PERLBUILDER] Skipping build of perl-$perlver-$perlopts due to known problems..." );
			return 0;
		}

		# kick off the build process!
		my $ret = do_build();

		# cleanup the build dir ( lots of space! )
		$path = File::Spec->catdir( $PATH, 'build', "perl-$perlver-$perlopts" );
		do_log( "[PERLBUILDER] Executing rmdir($path)" );
		File::Path::Tiny::rm( $path ) or die "Unable to rm ($path): $!";

		if ( ! $ret ) {
			# failed something during compiling, move on!
			return 0;
		}
	} else {
		# all done with configuring?
		if ( -e File::Spec->catfile( $path, 'ready.smoke' ) ) {
			do_log( "[PERLBUILDER] perl-$perlver-$perlopts is ready to smoke..." );
			return 1;
		} else {
			do_log( "[PERLBUILDER] perl-$perlver-$perlopts is already built..." );
		}
	}

	return customize_perl();
}

sub customize_perl {
	do_log( "[PERLBUILDER] Firing up the perl-$perlver-$perlopts installer..." );

	# do we have CPANPLUS already extracted?
	if ( ! do_initCPANP_BOXED() ) {
		return 0;
	}

	# we go ahead and configure CPANPLUS for this version :)
	if ( ! do_installCPANPLUS() ) {
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
	# force an update to make sure it's ready for smoking
	if ( ! do_cpanp_action( "perl-$perlver-$perlopts", "x --update_source" ) ) {
		return 0;
	}

	# Get rid of the man directory!
	my $path = File::Spec->catdir( $PATH, 'perls', "perl-$perlver-$perlopts" );
	my $mandir = File::Spec->catdir( $path, 'man' );
	if ( -d $mandir ) {
		do_log( "[FINALIZER] Executing rmdir($mandir)" );
		File::Path::Tiny::rm( $mandir ) or die "Unable to rm ($mandir): $!";
	}

	# get rid of the default pod...
#	/home/cpan/perls/perl-5.10.1-default/lib/5.10.1/pod/perlwin32.pod
#	/home/cpan/perls/perl-5.10.1-default/lib/5.10.1/pod/perlxs.pod
#	/home/cpan/perls/perl-5.10.1-default/lib/5.10.1/pod/perlxstut.pod
#	/home/cpan/perls/perl-5.10.1-default/lib/5.10.1/pod/a2p.pod
	my $poddir = File::Spec->catdir( $path, 'lib', $perlver, 'pod' );
	if ( -d $poddir ) {
		do_log( "[FINALIZER] Executing rmdir($poddir)" );
		File::Path::Tiny::rm( $poddir ) or die "Unable to rm ($poddir): $!";
	}

	# we're really done!
	my $readysmoke = File::Spec->catfile( $path, 'ready.smoke' );
	do_log( "[FINALIZER] Creating ready.smoke for '$path'" );
	open( my $file, '>', $readysmoke ) or die "Unable to open ($readysmoke): $!";
	print $file "perl-$perlver-$perlopts\n";
	close( $file ) or die "Unable to close ($readysmoke): $!";

	return 1;
}

sub do_prebuild {
	# remove the old dir so we have a consistent build process
	my $build_dir = File::Spec->catdir( $PATH, 'build', "perl-$perlver-$perlopts" );
	if ( -d $build_dir ) {
		do_log( "[PERLBUILDER] Executing rmdir($build_dir)" );
		File::Path::Tiny::rm( $build_dir ) or die "Unable to rm ($build_dir): $!";
	}

#	[PERLBUILDER] Firing up the perl-5.11.5-default installer...
#	[PERLBUILDER] perl-5.11.5-default is ready to smoke...
#	[PERLBUILDER] Firing up the perl-5.11.4-default installer...
#	[PERLBUILDER] Preparing to build perl-5.11.4-default
#	[EXTRACTOR] Preparing to extract '/export/home/cpan/build/perl-5.11.4.tar.gz'
#	Could not open file '/export/home/cpan/build/perl-5.11.4/AUTHORS': Permission denied at /usr/perl5/site_perl/5.8.4/Archive/Extract.pm line 812
#	Unable to read '/export/home/cpan/build/perl-5.11.4.tar.gz': Could not open file '/export/home/cpan/build/perl-5.11.4/AUTHORS': Permission denied at ./compile.pl line 1072
	# Just remove any old dir that was there ( script exited in the middle so it was not cleaned up )
	my $extract_dir = File::Spec->catdir( $PATH, 'build', "perl-$perlver" );
	if ( -d $extract_dir ) {
		do_log( "[PERLBUILDER] Executing rmdir($extract_dir)" );
		File::Path::Tiny::rm( $extract_dir ) or die "Unable to rm ($extract_dir): $!";
	}

	# Argh, we need to figure out the tarball - tar.gz or tar.bz2 or what??? ( thanks to perl-5.11.3 which didn't have a tar.gz file heh )
	opendir( PERLDIR, File::Spec->catdir( $PATH, 'build' ) ) or die "Unable to opendir: $!";
	my @tarballs = grep { /^perl\-$perlver.+/ } readdir( PERLDIR );
	closedir( PERLDIR ) or die "Unable to closedir: $!";
	if ( scalar @tarballs != 1 ) {
		# hmpf!
		do_log( "[PERLBUILDER] Perl tarball for $perlver not found!" );
		return 0;
	}

	# extract the tarball!
	if ( ! do_archive_extract( File::Spec->catfile( $PATH, 'build', $tarballs[0] ), File::Spec->catdir( $PATH, 'build' ) ) ) {
		return 0;
	}

	# TODO UGLY HACK FOR 5.12.0-RC0!
	if ( $perlver eq '5.12.0' ) {
		my $rc0path = File::Spec->catdir( $PATH, 'build', 'perl-5.12.0-RC0' );
		if ( -d $rc0path ) {
			$extract_dir = $rc0path;
		}
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
			do_log( "[PERLBUILDER] Removing problematic '" . join( '/', @$t ) . "' test" );
			unlink( $testpath ) or die "Unable to unlink ($testpath): $!";

			# argh, we have to munge MANIFEST
			do_shellcommand( "perl -nli -e 'print if ! /^" . quotemeta( join( '/', @$t ) ) . "/' $manipath" );
		}
	}

	return 1;
}

sub do_initCPANP_BOXED {
	do_log( "[CPANPLUS] Configuring CPANPLUS::Boxed..." );

	# Get the cpanplus version
	$CPANPLUS_ver = get_CPANPLUS_ver() if ! defined $CPANPLUS_ver;

	# do we have CPANPLUS already extracted?
	my $cpandir = File::Spec->catdir( $PATH, "CPANPLUS-$CPANPLUS_ver" );
	if ( -d $cpandir ) {
		do_log( "[CPANPLUS] Executing rmdir($cpandir)" );
		File::Path::Tiny::rm( $cpandir ) or die "Unable to rm ($cpandir): $!";
	}

	# do we have the tarball?
	$CPANPLUS_path = get_CPANPLUS_tarball_path() if ! defined $CPANPLUS_path;
	my $cpantarball = File::Spec->catfile( $PATH, ( File::Spec->splitpath( $CPANPLUS_path ) )[2] );
	if ( ! -f $cpantarball ) {
		# get it!
		do_shellcommand( "lwp-mirror ftp://192.168.0.200/CPAN/$CPANPLUS_path $cpantarball" );
	}

	# extract it!
	if ( ! do_archive_extract( $cpantarball, $PATH ) ) {
		return 0;
	}

# TODO - wait for new CPANPLUS version to solve this: http://rt.cpan.org/Ticket/Display.html?id=55541
# For now we just patch it...
	if ( $CPANPLUS_ver eq '0.9002' ) {
		do_log( "[CPANPLUS] Patching CPANPLUS-$CPANPLUS_ver for perl-core issue - RT#55541" );

		my $data = <<'EOF';
--- lib/CPANPLUS/Dist.pm.orig	2010-03-13 19:43:13.000000000 -0700
+++ lib/CPANPLUS/Dist.pm	2010-03-13 19:46:03.000000000 -0700
@@ -611,10 +611,10 @@
         ### part of core?
         if( $modobj->package_is_perl_core ) {
             error(loc("Prerequisite '%1' is perl-core (%2) -- not ".
-                      "installing that. Aborting install",
+                      "installing that. -- Note that the overall ".
+                      "install may fail due to this.",
                       $modobj->module, $modobj->package ) );
-            $flag++;
-            last;
+            next;
         }

         ### circular dependency code ###
EOF

		my $patchfile = File::Spec->catfile( $cpandir, 'cpanplus.patch' );
		open( my $patch, '>', $patchfile ) or die "Unable to create ($patchfile): $!";
		print $patch $data;
		close( $patch ) or die "Unable to close ($patchfile): $!";
		do_shellcommand( "patch -p0 -d $cpandir < $patchfile" );
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

#<Apocalypse> BinGOs: Wondering what you put in the CPANPLUS config on your smoking setup for makemakerflags and buildflags
#<@BinGOs> s conf makeflags UNINST=1 and s conf buildflags uninst=1
#<Apocalypse> Why the uninst? You chown root the perl dirs so nothing can instal there, right?
#<Apocalypse> Or is that for the initial perl build stage, where you want to make sure the modules you install override any core modules and they get deleted?
#<@BinGOs> habit
#<@BinGOs> and when I am updating
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
	$conf->set_conf( base => 'XXXCATDIR-XXXPATHXXX/CPANPLUS-XXXCPANPLUSXXX/.cpanplus/XXXUSERXXXXXX' );
	$conf->set_conf( buildflags => 'uninst=1' );
	$conf->set_conf( cpantest => 0 );
	$conf->set_conf( cpantest_mx => '' );
	$conf->set_conf( cpantest_reporter_args => {} );
	$conf->set_conf( debug => 0 );
	$conf->set_conf( dist_type => '' );
	$conf->set_conf( email => 'apocal@cpan.org' );
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
	$conf->set_conf( makeflags => 'UNINST=1' );
	$conf->set_conf( makemakerflags => '' );
	$conf->set_conf( md5 => 1 );
	$conf->set_conf( no_update => 1 );
	$conf->set_conf( passive => 1 );
	$conf->set_conf( prefer_bin => 1 );

# We let CPANPLUS automatically figure it out!
#	$conf->set_conf( prefer_makefile => 1 );

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
		$cpanp_dir = File::Spec->catdir( $PATH, "CPANPLUS-$CPANPLUS_ver", '.cpanplus', $ENV{USERNAME}, 'lib', 'CPANPLUS', 'Config' );
	} else {
		$cpanp_dir = File::Spec->catdir( $PATH, "CPANPLUS-$CPANPLUS_ver", '.cpanplus', $ENV{USER}, 'lib', 'CPANPLUS', 'Config' );
	}
	do_log( "[CPANPLUS] Executing mkdir($cpanp_dir)" );
	File::Path::Tiny::mk( $cpanp_dir ) or die "Unable to mkdir ($cpanp_dir): $!";

	$cpanp_dir = File::Spec->catfile( $cpanp_dir, 'Boxed.pm' );
	open( my $config, '>', $cpanp_dir ) or die "Unable to create ($cpanp_dir): $!";
	print $config $boxed;
	close( $config ) or die "Unable to close ($cpanp_dir): $!";

	return;
}

sub do_replacements {
	my $str = shift;

	# Smart file::spec->catdir support
	$str =~ s/XXXCATDIR\-(.+)XXX/do_replacements_slash( do_replacements_catdir( $1 ) )/ge;

	# basic stuff
	if ( $^O eq 'MSWin32' ) {
		$str =~ s/XXXUSERXXX/$ENV{USERNAME}/g;
	} else {
		$str =~ s/XXXUSERXXX/$ENV{USER}/g;
	}
	$str =~ s/XXXPATHXXX/do_replacements_slash( $PATH )/ge;

	# I'm sick of seeing Use of uninitialized value in concatenation (.) or string at ./compile.pl line 928.
	if ( defined $perlver ) {
		$str =~ s/XXXPERLVERXXX/$perlver-$perlopts/g;
	}
	if ( defined $CPANPLUS_ver ) {
		$str =~ s/XXXCPANPLUSXXX/$CPANPLUS_ver/g;
	}

	# find binary locations
	$str =~ s/XXXWHICH-([\w\-]+)XXX/do_replacements_slash( get_binary_path( $1 ) )/ge;

	return $str;
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

	# Add other useful toolchain modules
	push( @toolchain_modules, qw( File::Temp ) );

	return \@toolchain_modules;
}

# Look at do_installCPANP_BOXED_config for more details
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
	$conf->set_conf( base => 'XXXCATDIR-XXXPATHXXX/cpanp_conf/perl-XXXPERLVERXXX/.cpanplusXXX' );
	$conf->set_conf( buildflags => 'uninst=1' );
	$conf->set_conf( cpantest => 1 );
	$conf->set_conf( cpantest_mx => '' );
#	$conf->set_conf( cpantest_reporter_args => {
#		transport => 'HTTPGateway',
#		transport_args => [ 'http://192.168.0.200:11111/submit' ],
#	} );

#	$conf->set_conf( cpantest_reporter_args => {
#		transport => 'Metabase',
#		transport_args => [
#			uri => "https://metabase.cpantesters.org/beta/",
#			id_file => "XXXCATDIR-XXXPATHXXX/.metabase/id.jsonXXX",
#		],
#	} );

	$conf->set_conf( cpantest_reporter_args => {
		transport => 'Socket',
		transport_args => [
			host => '192.168.0.200',
			port => 11_111,
		],
	} );

	$conf->set_conf( debug => 0 );
	$conf->set_conf( dist_type => '' );
	$conf->set_conf( email => 'apocal@cpan.org' );
	$conf->set_conf( enable_custom_sources => 0 );
	$conf->set_conf( extractdir => '' );
	$conf->set_conf( fetchdir => '' );

# TODO seems like this causes weird caching issues - better to split off the stuff for now...
#	$conf->set_conf( fetchdir => 'XXXCATDIR-XXXPATHXXX/.cpanplus/authorsXXX' );

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
	$conf->set_conf( makeflags => 'UNINST=1' );
	$conf->set_conf( makemakerflags => '' );
	$conf->set_conf( md5 => 1 );
	$conf->set_conf( no_update => 1 );
	$conf->set_conf( passive => 1 );
	$conf->set_conf( prefer_bin => 1 );

# We let CPANPLUS automatically figure it out!
#	$conf->set_conf( prefer_makefile => 1 );

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
	$conf->set_program( perlwrapper => 'XXXCATDIR-XXXPATHXXX/perls/perl-XXXPERLVERXXX/bin/cpanp-run-perlXXX' );
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
	my $oldcpanplus = File::Spec->catdir( $PATH, 'cpanp_conf', "perl-$perlver-$perlopts" );
	if ( -d $oldcpanplus ) {
		do_log( "[CPANPLUS] Removing old CPANPLUS conf directory in '$oldcpanplus'" );
		File::Path::Tiny::rm( $oldcpanplus ) or die "Unable to rm ($oldcpanplus): $!";
	}

	# save it!
	my $cpanp_dir = File::Spec->catdir( $oldcpanplus, '.cpanplus', 'lib', 'CPANPLUS', 'Config' );
	do_log( "[CPANPLUS] Executing mkdir($cpanp_dir)" );
	File::Path::Tiny::mk( $cpanp_dir ) or die "Unable to mkdir ($cpanp_dir): $!";

	$cpanp_dir = File::Spec->catfile( $cpanp_dir, 'User.pm' );
	open( my $config, '>', $cpanp_dir ) or die "Unable to create ($cpanp_dir): $!";
	print $config $cpanplus;
	close( $config ) or die "Unable to close ($cpanp_dir): $!";

	# TODO figure out a way to symlink the $PATH/.cpanplus/sourcefiles.s2.21.c0.88.stored and 01mailrc.txt.gz and 02packages and 03modlist files to this dist...

	return;
}

sub do_cpanpboxed_action {
	my( $action ) = @_;

	# use default answer to prompts
	local $ENV{PERL_MM_USE_DEFAULT} = 1;
	local $ENV{PERL_EXTUTILS_AUTOINSTALL} = '--defaultdeps';
	local $ENV{TMPDIR} = File::Spec->catdir( $PATH, 'tmp' );
	return analyze_cpanp_install( $action, do_shellcommand( File::Spec->catfile( $PATH, 'perls', "perl-$perlver-$perlopts", 'bin', 'perl' ) . " " . File::Spec->catfile( $PATH, "CPANPLUS-$CPANPLUS_ver", 'bin', 'cpanp-boxed' ) . " $action" ) );
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
			return 0;
		}
	} else {
		# unknown action!
		return 0;
	}
}

sub do_cpanp_action {
	my( $perl, $action ) = @_;

	# use default answer to prompts
	local $ENV{PERL_MM_USE_DEFAULT} = 1;
	local $ENV{PERL_EXTUTILS_AUTOINSTALL} = '--defaultdeps';
	local $ENV{TMPDIR} = File::Spec->catdir( $PATH, 'tmp' );
	local $ENV{APPDATA} = File::Spec->catdir( $PATH, 'cpanp_conf', $perl );

	# special way for MSWin32...
	if ( $^O eq 'MSWin32' ) {
		local $ENV{PATH} = cleanse_strawberry_path();
		return analyze_cpanp_install( $action, do_shellcommand( "cpanp $action" ) );
	} else {
		return analyze_cpanp_install( $action, do_shellcommand( File::Spec->catfile( $PATH, 'perls', $perl, 'bin', 'perl' ) . " " . File::Spec->catfile( $PATH, 'perls', $perl, 'bin', 'cpanp' ) . " $action" ) );
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
	if ( $fails == 3 ) {
		do_log( "[SHELLCMD] Giving up trying to execute command, ABORTING!" );
		exit;
	} else {
		do_log( "[SHELLCMD] Done executing, retval = " . ( $retval >> 8 ) );
	}

	my @output = split( /\n/, $output );
	return \@output;
}

sub do_build {
	# ignore the args for now, as we use globals :(
	do_log( "[PERLBUILDER] Preparing to build perl-$perlver-$perlopts" );

	# do prebuild stuff
	if ( ! do_prebuild() ) {
		return 0;
	}

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
		# Is it ok to proceed?
		if ( ! check_perl_build( $output ) ) {
			do_log( "[PERLBUILDER] Unable to compile perl-$perlver-$perlopts!" );
			return 0;
		}
	}

	# make sure we pass tests
	$output = do_shellcommand( "cd $PATH/build/perl-$perlver-$perlopts; make test" );
	if ( ! fgrep( '^All\s+tests\s+successful\.$', $output ) ) {
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

# checks for "allowed" build failures ( known problems )
sub check_perl_build {
	my $output = shift;

	# freebsd is wack... throws errors for no idea ( I think, hah! )
	#cp Errno.pm ../../lib/Errno.pm
	#
	#	Everything is up to date. Type 'make test' to run test suite.
	#*** Error code 1 (ignored)
	if ( $^O eq 'freebsd' and $perlver =~ /^5\.8\./ and $output->[-1] eq '*** Error code 1 (ignored)' ) {
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
	if ( $^O eq 'netbsd' and $perlver =~ /^5\.8\./ and $output->[-1] eq ' (ignored)' ) {
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
		if ( $^O eq 'netbsd' and $perlver =~ /^5\.6\./ and fgrep( 'pragma/locale\.+(?!ok)', $output ) ) {
			do_log( "[PERLBUILDER] Detected locale test failure on netbsd for perl-5.6.x, ignoring it..." );
			return 1;
		}

		# TODO 5.8.x < 5.8.9 on freebsd has hostname problems... dunno why
		#lib/Net/t/hostname........................FAILED at test 1
		if ( $perlver =~ /^5\.8\./ and $^O eq 'freebsd' and fgrep( '^lib/Net/t/hostname\.+(?!ok)', $output ) ) {
			do_log( "[PERLBUILDER] Detected hostname test failure on freebsd for perl-5.8.x, ignoring it..." );
			return 1;
		}
	} elsif ( fgrep( '^Failed\s+2\s+test', $output ) ) {
		# 5.8.8 has known problems with sprintf.t and sprintf2.t
		#t/op/sprintf..............................FAILED--no leader found
		#t/op/sprintf2.............................FAILED--expected 263 tests, saw 3
		if ( $perlver eq '5.8.8' and fgrep( '^t/op/sprintf\.+(?!ok)', $output ) ) {
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
		my $patchfile = File::Spec->catfile( $PATH, 'build', "perl-$perlver-$perlopts", "patch.$patch_num" );
		open( my $patch, '>', $patchfile ) or die "Unable to create ($patchfile): $!";
		print $patch $patchdata;
		close( $patch ) or die "Unable to close ($patchfile): $!";

		do_shellcommand( "patch -p0 -d " . File::Spec->catdir( $PATH, 'build', "perl-$perlver-$perlopts" ) . " < $patchfile" );
#		unlink("build/perl-$perlver-$perlopts/patch.$patch_num") or die "unable to unlink patchfile: $!";
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

	# load the hints/netbsd.sh from perl-5.11.5
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
	do_replacefile( File::Spec->catfile( $PATH, 'build', "perl-$perlver-$perlopts", 'hints', 'netbsd.sh' ), $data );

	return;
}

sub patch_hints_freebsd {
	# same strategy as netbsd, we need it...

	# load the hints/freebsd.sh from perl-5.11.5
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

	do_replacefile( File::Spec->catfile( $PATH, 'build', "perl-$perlver-$perlopts", 'hints', 'freebsd.sh' ), $data );

	return;
}

sub do_replacefile {
	my( $file, $data ) = @_;
	do_log( "[PERLBUILDER] Replacing file '$file' with new data" );

	# for starters, we delete the file
	unlink( $file ) or die "Unable to unlink '$file': $!";
	open( my $f, '>', $file ) or die "Unable to open '$file' for writing: $!";
	print $f $data;
	close( $f ) or die "Unable to close '$file': $!";

	return;
}
