###############################################
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
    $conf->set_conf( base => '/home/apoc/perl/CPANPLUS-0.84/.cpanplus/apoc' );    
    $conf->set_conf( buildflags => '' );    
    $conf->set_conf( cpantest => 0 );    
    $conf->set_conf( cpantest_mx => '' );    
    $conf->set_conf( debug => 0 );    
    $conf->set_conf( dist_type => '' );    
    $conf->set_conf( email => 'cpanplus@example.com' );    
    $conf->set_conf( extractdir => '' );    
    $conf->set_conf( fetchdir => '' );    
    $conf->set_conf( flush => 1 );    
    $conf->set_conf( force => 1 );    
    $conf->set_conf( hosts => [
	  {
	    'path' => '/home/apoc/perl/minicpan/',
	    'scheme' => 'file',
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
    $conf->set_conf( storable => 1 );    
    $conf->set_conf( timeout => 300 );    
    $conf->set_conf( verbose => 1 );    
    $conf->set_conf( write_install_logs => 1 );
    
    
    ### program section    
    $conf->set_program( editor => '/usr/bin/vi' );    
    $conf->set_program( make => '/usr/bin/make' );    
    $conf->set_program( pager => '/usr/bin/less' );    
    $conf->set_program( perlwrapper => '/usr/local/bin/cpanp-run-perl' );    
    $conf->set_program( shell => '/bin/bash' );    
    $conf->set_program( sudo => undef );    
    
    


    return 1;    
} 

1;

