#!/usr/bin/perl
use strict; use warnings;

# make sure we already installed all the distro libraries we need
# e.x. libncurses, libgtk, etc via apt-get or emerge or whatever
# it's a LOT of libs and some stupid wrangling...

# We have successfully compiled those perl versions:
# 5.6.0, 5.6.1, 5.6.2
# 5.8.0, 5.8.1, 5.8.2, 5.8.3, 5.8.4, 5.8.5

# TODO
# CPANPLUS won't work on 5.6.0, also some modules we want to install doesn't like 5.6.x :(

# this script does everything, but we need some layout to be specified!
# /home/apoc/perl				<-- the main directory
# /home/apoc/perl/minicpan			<-- the minicpan sources for CPANPLUS to use
# /home/apoc/perl/CPANPLUS-0.XX			<-- the extracted CPANPLUS directory we use
# /home/apoc/perl/build				<-- where we store our perl builds + tarballs
# /home/apoc/perl/build/perl-5.6.2.tar.gz	<-- one perl tarball
# /home/apoc/perl/build/perl-5.6.2		<-- one extracted perl build
# /home/apoc/perl/perl-5.6.2			<-- finalized perl install
# /home/apoc/perl/compile_perl.pl		<-- where this script should be

# load our dependencies
use Capture::Tiny qw( capture_merged tee_merged );

# get our perl version to build
my $perlver = $ARGV[0];
if ( ! defined $perlver ) {
	die "please supply a Perl version to build - e.x. 5.8.8";
}

# default DEBUG is 0
my $DEBUG = $ARGV[1] || 0;

# have we already compiled+installed this version?
if ( ! -d "perl-$perlver" ) {
	# do prebuild stuff
	do_prebuild();

	# kick off the build process!
	do_build();
} else {
	print "[COMPILER] Perl-$perlver is already installed...\n";
}

# we go ahead and configure CPANPLUS for this version :)
do_installCPANPLUS();

# finally, install our POE stuff
do_installPOE();

# all done!
exit 0;

sub do_prebuild {
	if ( ! -f "build/perl-$perlver.tar.gz" ) {
		# TODO auto download of tarball
		die "Perl version $perlver tarball isn't found in build/ directory";
	}
	if ( -d "build/perl-$perlver" ) {
		# remove it so we have a consistent build process
		do_shellcommand( "rm -rf build/perl-$perlver" );
	}

	# extract the tarball!
	do_shellcommand( "tar -C build -zxf build/perl-$perlver.tar.gz" );

	# now, apply the patches each version needs
	do_prebuild_patches();
}

sub do_installCPANPLUS {
	print "[COMPILER] Configuring CPANPLUS...\n";

	# do we have CPANPLUS already extracted?
	if ( ! -d "CPANPLUS-0.84" ) {
		# do we have the tarball?
		if ( ! -f "CPANPLUS-0.84.tar.gz" ) {
			# get it!
			do_shellcommand( "wget http://search.cpan.org/CPAN/authors/id/K/KA/KANE/CPANPLUS-0.84.tar.gz" );
		}

		# extract it!
		do_shellcommand( "tar -zxf CPANPLUS-0.84.tar.gz" );

		# TODO configure the Boxed Config settings
		# we need to disable: signature, allow_build_interactivity, and show_startup_tip
		# we need to enable: no_update
		# we need to add the local minicpan mirror as the ONLY mirror, so we don't waste inet bw
	} else {
		# make sure the appdata directory is "clean"
		if ( -d "CPANPLUS-0.84/.cpanplus/$ENV{USER}/$perlver" ) {
			do_shellcommand( "rm -rf CPANPLUS-0.84/.cpanplus/$ENV{USER}/$perlver" );
		}
	}

	# use cpanp-boxed to install some modules that we know we need to bootstrap, argh! ( mostly found via 5.6.1 )
	do_shellcommand( "/home/$ENV{USER}/perl/perl-$perlver/bin/perl CPANPLUS-0.84/bin/cpanp-boxed i ExtUtils::MakeMaker Test::More File::Temp" );

	# run the cpanp-boxed script and tell it to bootstrap it's dependencies
	do_shellcommand( "/home/$ENV{USER}/perl/perl-$perlver/bin/perl CPANPLUS-0.84/bin/cpanp-boxed s selfupdate dependencies" );
	do_shellcommand( "/home/$ENV{USER}/perl/perl-$perlver/bin/perl CPANPLUS-0.84/bin/cpanp-boxed s selfupdate enabled_features" );

	# finally, install CPANPLUS!
	do_shellcommand( "/home/$ENV{USER}/perl/perl-$perlver/bin/perl CPANPLUS-0.84/bin/cpanp-boxed i CPANPLUS" );

	# TODO configure the installed CPANPLUS?
}

sub do_installPOE {
	# install POE's dependencies!
	# The ExtUtils modules are for Glib, which doesn't specify it in the "normal" way, argh!
	do_shellcommand( "/home/$ENV{USER}/perl/perl-$perlver/bin/perl CPANPLUS-0.84/bin/cpanp-boxed i Test::Pod Test::Pod::Coverage Socket6 Time::HiRes Term::ReadKey Term::Cap IO::Pty URI LWP Module::Build Curses ExtUtils::Depends ExtUtils::PkgConfig" );

	# install POE itself to pull in some more stuff
	do_shellcommand( "/home/$ENV{USER}/perl/perl-$perlver/bin/perl CPANPLUS-0.84/bin/cpanp-boxed i POE" );

	# install our POE loops + their dependencies
	foreach my $loop ( qw( Event Tk Gtk Wx Prima IO::Poll Glib EV ) ) {
		# skip problematic loops
		if ( $perlver =~ /^5\.6\./ and ( $loop eq 'Tk' or $loop eq 'Wx' or $loop eq 'Event' or $loop eq 'Glib' ) ) {
			next;
		}

		do_shellcommand( "/home/$ENV{USER}/perl/perl-$perlver/bin/perl CPANPLUS-0.84/bin/cpanp-boxed i $loop" );
		
		# stupid differing loops
		my $poeloop = $loop;
		$poeloop = 'IO_Poll' if $loop eq 'IO::Poll';
		do_shellcommand( "/home/$ENV{USER}/perl/perl-$perlver/bin/perl CPANPLUS-0.84/bin/cpanp-boxed i POE::Loop::$poeloop" );
	}
}

sub do_shellcommand {
	my $cmd = shift;

	print "[COMPILER] Executing $cmd\n";
	my $output;
	if ( $DEBUG ) {
		$output = tee_merged { system( $cmd ) };
	} else {
		$output = capture_merged { system( $cmd ) };
	}
	my @output = split( /\n/, $output );
	return \@output;
}

sub do_build {
	# we start off with the Configure step
	my $extraoptions = '';
	if ( $perlver =~ /^5\.6\./ ) {
		# disable DB_File support ( buggy )
		$extraoptions .= '-Ui_db';
	} elsif ( $perlver =~ /^5\.8\./ ) {
		# disable DB_File support ( buggy )
		$extraoptions .= '-Ui_db';
	}

	# actually do the configure!
	do_shellcommand( "cd build/perl-$perlver; sh Configure -des -Dprefix=/home/apoc/perl/perl-$perlver $extraoptions" );

	# some versions need extra patching after the Configure part :(
	do_premake_patches();

	# generate dependencies - not needed because Configure -des defaults to automatically doing it
	#do_shellcommand( "cd build/perl-$perlver; make depend" );

	# actually compile!
	my $output = do_shellcommand( "cd build/perl-$perlver; make" );
	if ( $output->[-1] !~ /to\s+run\s+test\s+suite/ ) {
		die "Unable to Compile perl-$perlver!\n";
	}

	# make sure we pass tests
	$output = do_shellcommand( "cd build/perl-$perlver; make test" );
	if ( ! grep { /^All\s+tests\s+successful\.$/ } @$output ) {
		# TODO argh, file::find often fails, need to track down why it happens
		if ( grep { /^Failed\s+1\s+test/ } @$output and grep { m|^lib/File/Find/t/find\.+FAILED| } @$output ) {
			print "[COMPILER] Detected File::Find test failure, ignoring it...\n";
		} else {
			die "Testsuite failed!";
		}
	}

	# okay, do the install!
	do_shellcommand( "cd build/perl-$perlver; make install" );

	# all done!
	print "[COMPILER] Installed perl-$perlver successfully!\n";
}

sub do_premake_patches {
	# do we need to do anything?
}

sub do_prebuild_patches {
	# okay, what version is this?
	if ( $perlver =~ /^5\.8\.(\d+)$/ ) {
		my $v = $1;
		if ( $v == 0 or $v == 1 or $v == 2 or $v == 3 or $v == 4 or $v == 5 ) {
			patch_makedepend_escape();

			patch_makedepend_cleanups_580();
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
			patch_makedepend_addcleanups_561();
		} elsif ( $v == 0 ) {
			patch_makedepend_addcleanups_560();
		}
	}
}

sub do_patch {
	my( $patchdata ) = @_;

	# okay, apply it!
	open( my $patch, '>', "build/perl-$perlver/patch.diff" ) or die "unable to create patchfile: $@";
	print $patch $patchdata;
	close( $patch );
	do_shellcommand( "patch -p0 -d build/perl-$perlver < build/perl-$perlver/patch.diff" );
	unlink("build/perl-$perlver/patch.diff") or die "unable to unlink patchfile: $@";
	return 1;	
}	

sub patch_asmpageh {
	# from http://www.nntp.perl.org/group/perl.perl5.porters/2007/08/msg127609.html
	my $data = <<'EOF';
--- ext/IPC/SysV/SysV.xs.orig
+++ ext/IPC/SysV/SysV.xs
@@ -3,9 +3,6 @@
 #include "XSUB.h"

 #include <sys/types.h>
-#ifdef __linux__
-#   include <asm/page.h>
-#endif
 #if defined(HAS_MSG) || defined(HAS_SEM) || defined(HAS_SHM)
 #ifndef HAS_SEM
 #   include <sys/ipc.h>
@@ -21,9 +18,14 @@
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
+#      elif defined(__linux__)
+#          include <asm/page.h>         =20
 #      endif
 #   endif
 #endif
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

sub patch_makedepend_cleanups_580 {
	# from http://perl5.git.perl.org/perl.git/commitdiff/2bce232
	my $data = <<'EOF';
--- makedepend.SH.orig
+++ makedepend.SH
@@ -157,6 +157,7 @@
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

sub patch_makedepend_addcleanups_561 {
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

sub patch_makedepend_addcleanups_560 {
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
