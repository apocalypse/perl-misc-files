#!/usr/bin/perl
use strict; use warnings;

# This script takes the cpanstats DB and outputs it into a format
# that Gource likes. What I am going to do is emulate the Git formatting

# Grab the cpanstats DB from http://devel.cpantesters.org/cpanstats.db.bz2
# Get the cpantesters mapping from a magic fairy ;)

# Warning: the resulting log will be ~400M as of March 16, 2010!

# TODO use Term::ProgressBar and calculate the total number of rows + update the term...

# some misc configs
my $cpanstats = '/home/apoc/Desktop/cpanstats.db';
my $cpan_map = '/home/apoc/Desktop/cpantesters_mapping.txt';

# Load our modules!
use DBI;
use DateTime;
use Data::GUID::Any qw( guid_as_string );

main();

sub main {
	# Load the cpantesters mapping
	load_cpantesters_map();

	# Connect to the sqlite DB!
	my $dbh = DBI->connect( "dbi:SQLite:dbname=$cpanstats", '', '', {
		'PrintError'	=>	1,
		'PrintWarn'	=>	1,
		'RaiseError'	=>	1,
		'TraceLevel'	=>	0,
	} );

	# Pull out each upload and process it
	# TODO should be ORDER BY date but it blows up? The column is not a true date column so...
	my $sth = $dbh->prepare( 'SELECT id, tester, platform, perl, osname, osvers, date FROM cpanstats ORDER BY id' );
	$sth->execute;
	my $newdata;
	$sth->bind_columns( \( @$newdata{ @{ $sth->{'NAME_lc'} } } ) );

	# Start with the header
	# set the date as 935824000 which is right before id 1 in the DB :)
	print "user:APOCALYPSE\n935824000\n:000000 100644 0000000... bd3b6ca... A	perl/\n\n";

	while ( $sth->fetch() ) {
		# Process this report
		process_report( $newdata );
	}
	$sth->finish;
	undef $sth;
	$dbh->disconnect;
	undef $dbh;
	return;
}

# Stores the uploader -> name mapping
my %cpantesters_map;

sub load_cpantesters_map {
	my %temp;

	open( my $fh, '<', $cpan_map ) or die "Unable to load '$cpan_map': $!";
	while ( <$fh> ) {
		chomp;
		my ( $email, $name ) = $_ =~ m{\A(.+),(.+)\z};
		die "Couldn't parse >>>$_<<<" unless $email && $name;
		push @{ $temp{ $name } }, $email;
	}
	close( $fh ) or die "Unable to close '$cpan_map': $!";

	# reverse it so we can search by email and get the name
	foreach my $name ( keys %temp ) {
		foreach my $email ( @{ $temp{ $name } } ) {
			$cpantesters_map{ $email } = $name;
		}
	}
}

sub find_cpantesters_map {
	my $email = shift;

	# Sanity
	return 'UNKNOWN' if ! defined $email or ! length $email;
	if ( exists $cpantesters_map{ $email } ) {
		return $cpantesters_map{ $email };
	} else {
		return $email;
	}
}

# Stores the tree we've used to generate the layout
# top-level: "perl"
# sub-level: perl versions
# sub-sub level: osname
# sub-sub-sub level: platform-osver
my %tree;

my $last_report_id = 0;

sub process_report {
	my $r = shift;
	my %report = %$r;

#	use Data::Dumper;
#	print Dumper( \%report );

	# Mangle the date into an epoch
	# from CPAN::Testers::Data::Generator: whereas the 'date' field refers to the YYYYMMDDhhmm formatted date and time.
	if ( $report{date} =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})$/ ) {
		$report{date} = DateTime->new(
			year	=> $1,
			month	=> $2,
			day	=> $3,
			hour	=> $4,
			minute	=> $5,
		)->epoch;
	} else {
		warn "Invalid date in report: $report{date}";
		return;
	}

	# Cleanup some vars
	$report{tester} = find_cpantesters_map( $report{tester} );
	$report{platform} = 'UNKNOWN' if ! defined $report{platform} or ! length $report{platform};
	$report{osname} = 'UNKNOWN' if ! defined $report{osname} or ! length $report{osname};
	$report{osvers} = 'UNKNOWN' if ! defined $report{osvers} or ! length $report{osvers};
	$report{perl} = 'UNKNOWN' if ! defined $report{perl} or ! length $report{perl};
	$report{perl} = 'UNKNOWN' if length $report{perl} == 1;	# to shut up perl = 0 reports...
	my $guid = substr( guid_as_string(), 0, 7 );
	my $os = $report{platform} . ' (' . $report{osvers} . ')';

	# Generate the git output!
	my $output = "user:$report{tester}\n";
	$output .= $report{date} . "\n";

	# git output is:
	#:000000 100644 0000000... bd3b6ca... A	poe/lib/POE/Kernel.pm
	#:000000 100644 0000000... 83c9f1a... A	poe/lib/POE/Session.pm
	#:100644 100644 bd3b6ca... 63d6c22... M	poe/lib/POE/Kernel.pm
	#:(old file mask - 0 if A) (new file mask - 0 if A) (parent guid - 0 if A) (new guid) (mode - A for add, M for modify) (path)
	if ( exists $tree{ $report{perl} }{ $report{osname} }{ $os } ) {
		$output .= ":100644 100644 " .
			$tree{ $report{perl} }{ $report{osname} }{ $os } .
			"... $guid... M\tperl/$report{perl}/$report{osname}/$os\n";

		$tree{ $report{perl} }{ $report{osname} }{ $os } = $guid;
	} else {
		$tree{ $report{perl} }{ $report{osname} }{ $os } = $guid;
		$output .= ":000000 100644 0000000... $guid... A\tperl/$report{perl}/$report{osname}/$os\n";
	}
	$output .= "\n";

	print $output;
	return;
}

__END__

# to generate the video, run this script and save the log, then run Gource like this:
# You would need to experiment with the "-r 200" param to ffmpeg to get an optimal video!
gource gource_cpantesters.log -1280x720 --highlight-all-users --multi-sampling --user-scale 0.5 \
  --disable-bloom --elasticity 0.0001 --max-file-lag 0.000001 --max-files 1000000 \
  --date-format "CPANTesters Upload Activity On %B %d, %Y %X" --stop-on-idle -s 0.000001 \
  --colour-images --user-friction 0.0000001 \
  --output-ppm-stream - | ffmpeg -y -b 5000K -r 200 -f image2pipe -vcodec ppm -i - -vcodec mpeg4 gource_CT.mp4


apoc@blackhole:~/othergit/poe$ gource --git-log-command perl/
git log --pretty=format:user:%aN%n%ct --reverse --raw --encoding=UTF-8 --no-renames

# from man git log:
# %aN: author name (respecting .mailmap, see git-shortlog(1) or git-blame(1))
# %ct: committer date, UNIX timestamp
# %n: newline

# It looks something like this:

apoc@blackhole:~/othergit/poe$ git log --pretty=format:user:%aN%n%ct --reverse --raw --encoding=UTF-8 --no-renames
user:(no author)
902692078
user:troc
902692078
:000000 100644 0000000... bd3b6ca... A	poe/lib/POE/Kernel.pm
:000000 100644 0000000... 83c9f1a... A	poe/lib/POE/Session.pm
:000000 100755 0000000... cb894d8... A	poe/samples/sessions.perl

user:troc
902718149
:000000 100755 0000000... 1cca884... A	poe/samples/forkbomb.perl

user:troc
902718224
:100644 100644 83c9f1a... 409f349... M	poe/lib/POE/Session.pm

user:troc
902718270
:100644 100644 bd3b6ca... 63d6c22... M	poe/lib/POE/Kernel.pm

user:troc
902718309
:100755 100755 cb894d8... 07795ee... M	poe/samples/sessions.perl

user:troc
902781107
:000000 100755 0000000... 1de58f2... A	poe/samples/selects.perl

$VAR1 = {
          'perl' => '0',
          'osname' => '',
          'date' => 935824080,
          'id' => 1,
          'platform' => '',
          'tester' => 'ABH',
          'osvers' => ''
        };
$VAR1 = {
          'perl' => '0',
          'osname' => '',
          'date' => 935825520,
          'id' => 2,
          'platform' => '',
          'tester' => 'KWILLIAMS',
          'osvers' => ''
        };
$VAR1 = {
          'perl' => '0',
          'osname' => '',
          'date' => 935837940,
          'id' => 3,
          'platform' => '',
          'tester' => 'ABH',
          'osvers' => ''
        };
$VAR1 = {
          'perl' => '0',
          'osname' => '',
          'date' => 935843880,
          'id' => 4,
          'platform' => '',
          'tester' => 'EGROSS',
          'osvers' => ''
        };
$VAR1 = {
          'perl' => '0',
          'osname' => '',
          'date' => 935844600,
          'id' => 5,
          'platform' => '',
          'tester' => 'MADWOLF',
          'osvers' => ''
        };
$VAR1 = {
          'perl' => '5.5.3',
          'osname' => 'solaris',
          'date' => 935842440,
          'id' => 6,
          'platform' => 'sun4-solaris',
          'tester' => 'schinder@pobox.com',
          'osvers' => '2.7'
        };
$VAR1 = {
          'perl' => '5.4.4',
          'osname' => 'hpux',
          'date' => 935842500,
          'id' => 7,
          'platform' => 'PA-RISC1.1',
          'tester' => 'schinder@pobox.com',
          'osvers' => '10.20'
        };
$VAR1 = {
          'perl' => '5.4.4',
          'osname' => 'hpux',
          'date' => 935842740,
          'id' => 9,
          'platform' => 'PA-RISC1.1',
          'tester' => 'schinder@pobox.com',
          'osvers' => '10.20'
        };
$VAR1 = {
          'perl' => '5.5.3',
          'osname' => 'solaris',
          'date' => 935842920,
          'id' => 12,
          'platform' => 'sun4-solaris',
          'tester' => 'schinder@pobox.com',
          'osvers' => '2.7'
        };
$VAR1 = {
          'perl' => '5.4.4',
          'osname' => 'hpux',
          'date' => 935843400,
          'id' => 13,
          'platform' => 'PA-RISC1.1',
          'tester' => 'schinder@pobox.com',
          'osvers' => '10.20'
        };
$VAR1 = {
          'perl' => '5.5.3',
          'osname' => 'solaris',
          'date' => 935843400,
          'id' => 14,
          'platform' => 'sun4-solaris',
          'tester' => 'schinder@pobox.com',
          'osvers' => '2.7'
        };
