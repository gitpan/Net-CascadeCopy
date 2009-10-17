#!perl
use Test::More tests => 7;
use strict;

# use Log::Log4perl qw(:easy);

# my $conf =<<END_LOG4PERLCONF;
# # Screen output at INFO level
# log4perl.rootLogger=DEBUG, SCREEN

# # Info to screen and logfile
# log4perl.appender.SCREEN.Threshold=INFO
# log4perl.appender.SCREEN=Log::Log4perl::Appender::ScreenColoredLevels
# log4perl.appender.SCREEN.layout=PatternLayout
# log4perl.appender.SCREEN.layout.ConversionPattern=%d %m%n
# log4perl.appender.SCREEN.stderr=0

# END_LOG4PERLCONF

# Log::Log4perl::init( \$conf );

use Net::CascadeCopy;

my $transfer_start = new Benchmark;

my $ccp = Net::CascadeCopy->new( { ssh => 'echo' } );
$ccp->set_command( "echo" );
$ccp->set_source_path( "/foo" );
$ccp->set_target_path( "/foo" );

ok( $ccp->add_group( "only", [ 'host1' ] ),
    "Adding a single host to a single group"
);
is_deeply( [ $ccp->_get_available_servers( 'only' ) ],
           [ 'localhost' ],
           "Checking that only localhost is available"
       );

is_deeply( [ $ccp->_get_remaining_servers( 'only' ) ],
           [ 'host1' ],
           "Checking that host1 is remaining"
       );

ok( $ccp->_transfer_loop( $transfer_start ),
    "Executing a single transfer loop"
);

sleep 1;

$ccp->_check_for_completed_processes();

is_deeply( [ $ccp->_get_remaining_servers( 'only' ) ],
           [],
           "Checking that one servers is no longer in the only group"
       );

# code_smell: localhost shouldn't really be in this list
is_deeply( [ $ccp->_get_available_servers( 'only' ) ],
           [ 'host1', 'localhost' ],
           "Checking that one servers is now available in only group"
       );

ok( ! $ccp->_transfer_loop( $transfer_start ),
    "making sure no loops left to run"
);
