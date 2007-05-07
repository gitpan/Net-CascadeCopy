package Net::CascadeCopy;
use warnings;
use strict;

use Carp;
use Log::Log4perl qw(:easy);
use POSIX ":sys_wait_h"; # imports WNOHANG
use Proc::Queue size => 16, debug => 0, trace => 0, delay => 1;
use version; our $VERSION = qv('0.0.3');

my $logger = get_logger( 'default' );

# inside-out Perl class
use Class::Std::Utils;
{
    my %data_of;

    # ssh command used to log in to remote server in order to run command
    my %ssh_of;
    my %ssh_args_of;

    # copy command
    my %command_of;
    my %command_args_of;

    # path to be copied
    my %source_path_of;
    my %target_path_of;

    # options for output
    my %output_of;

    # maximum number of failures per server
    my %max_failures_of;

    # maximum processes per remote server
    my %max_forks_of;

    # Constructor takes path of file system root directory...
    sub new {
        my ($class, $arg_ref) = @_;

        # Bless a scalar to instantiate the new object...
        my $new_object = bless \do{my $anon_scalar}, $class;


        # Initialize the object's attributes...
        $ssh_of{ident $new_object}          = $arg_ref->{ssh}          || "ssh";
        $ssh_args_of{ident $new_object}     = $arg_ref->{ssh_args}     || "-x -A";
        $max_failures_of{ident $new_object} = $arg_ref->{max_failures} || 3,
        $max_forks_of{ident $new_object}    = $arg_ref->{max_forks}    || 2;
        $output_of{ident $new_object}       = $arg_ref->{output};

        return $new_object;
    }

    # Retrieve files from root directory...
    sub _get_data {
        my ($self) = @_;
        return $data_of{ident $self};
    }

    sub set_command {
        my ( $self, $command, $args ) = @_;

        $command_of{ident $self} = $command;
        $command_args_of{ident $self} = $args;
    }

    sub set_source_path {
        my ( $self, $path ) = @_;
        $source_path_of{ident $self} = $path;
    }

    sub set_target_path {
        my ( $self, $path ) = @_;
        $target_path_of{ident $self} = $path;
    }

    sub add_group {
        my ( $self, $group, $servers_a ) = @_;

        $logger->info( "Adding group: $group: ",
                       join( ", ", @$servers_a ),
                   );

        # initialize data structures
        $data_of{ident $self}->{remaining}->{ $group } = $servers_a;

        # first server to transfer from is the current server
        push @{ $data_of{ident $self}->{available}->{ $group } }, 'localhost';

        # initialize data structures
        $data_of{ident $self}->{completed}->{ $group } = [];

    }

    sub transfer {
        my ( $self ) = @_;

        while ( 1 ) {
            $self->_check_for_completed_processes();

            # keep track if there are any remaining servers in any groups
            my ( $remaining_flag, $available_flag );

            # iterate through groups with reamining servers
            for my $group ( $self->_get_remaining_groups() ) {

                # there are still available servers to sync
                if ( $self->_has_available_server( $group )  ) {
                    my $source = $self->_reserve_available_server( $group );

                    my $busy;
                    for my $fork ( 1 .. $max_forks_of{ident $self} ) {
                        next if $source eq "localhost" && $fork > 1;
                        if ( $self->_has_remaining_server( $group ) ) {

                            my $target = $self->_reserve_remaining_server( $group );
                            $self->_start_process( $group, $source, $target );
                            $busy++;
                        }
                    }

                    unless ( $busy ) {
                        $logger->debug( "No remaining servers for available server $source" );
                        $self->_unreserve_available_server( $source );
                    }
                }
            }

            if ( ! $data_of{ident $self}->{remaining} && ! $data_of{ident $self}->{running} ) {
                $logger->debug( "All done" );
                exit;
            }

            sleep 1;
        }
    }

#
#__* start_process()
#

    sub _start_process {
        my ( $self, $group, $source, $target ) = @_;

        my $f=fork;
        if (defined ($f) and $f==0) {

            my $command;
            #my $command = "scp /tmp/foo $target:/tmp/foo";
            if ( $source eq "localhost" ) {
                $command = join " ", $command_of{ident $self},
                                     $command_args_of{ident $self},
                                     $source_path_of{ident $self},
                                     "$target:$target_path_of{ident $self}";
            }
            else {
                $command = join " ", $ssh_of{ident $self},
                                     $ssh_args_of{ident $self},
                                     $source,
                                     $command_of{ident $self},
                                     $command_args_of{ident $self},
                                     $target_path_of{ident $self},
                                     "$target:$target_path_of{ident $self}";
            }

            $logger->debug( "$command" );
            $logger->debug( "Starting new child: $command" );

            if ( my $output = $output_of{ident $self} ) {
                if ( $output eq "stdout" ) {
                    # don't modify command
                } elsif ( $output eq "log" ) {
                    # redirect all child output to log
                    $command = "$command >> ccp.$target.log 2>&1"
                } else {
                    # default is to redirectout stdout to /dev/null
                    $command = "$command >/dev/null"
                }
            }
            system( $command );

            if ($? == -1) {
                $logger->logconfess( "failed to execute: $!" );
            } elsif ($? & 127) {
                $logger->logconfess( sprintf "child died with signal %d, %s coredump",
                                     ($? & 127),  ($? & 128) ? 'with' : 'without'
                                 );
            } else {
                my $exit_status = $? >> 8;
                if ( $exit_status ) {
                    $logger->error( "child exit status: $exit_status" );
                }
                exit $exit_status;
            }
        } else {
            $data_of{ident $self}->{running}->{ $f } = { group => $group,
                                                         source => $source,
                                                         target => $target,
                                                     };
        }
    }

    sub _check_for_completed_processes {
        my ( $self ) = @_;

        return unless $data_of{ident $self}->{running};

        # find any processes that ended and reschedule the source and
        # target servers in the available pool
        for my $pid ( keys %{ $data_of{ident $self}->{running} } ) {
            if ( waitpid( $pid, WNOHANG) ) {

                # check the exit status of the command.
                if ( $? ) {
                    $self->_failed_process( $pid );
                } else {
                    $self->_succeeded_process( $pid );
                }
            }
        }

        unless ( keys %{ $data_of{ident $self}->{running} } ) {
            delete $data_of{ident $self}->{running};
        }
    }

    sub _succeeded_process {
        my ( $self, $pid ) = @_;

        my $group = $data_of{ident $self}->{running}->{ $pid }->{group};
        my $source = $data_of{ident $self}->{running}->{ $pid }->{source};
        my $target = $data_of{ident $self}->{running}->{ $pid }->{target};

        $logger->warn( "Succeeded: ($group) $source => $target  ($pid)" );

        $self->_mark_available( $group, $source );
        $self->_mark_completed( $group, $target );
        $self->_mark_available( $group, $target );

        delete $data_of{ident $self}->{running}->{ $pid };
    }


    sub _failed_process {
        my ( $self, $pid ) = @_;

        my $group  = $data_of{ident $self}->{running}->{ $pid }->{group};
        my $source = $data_of{ident $self}->{running}->{ $pid }->{source};
        my $target = $data_of{ident $self}->{running}->{ $pid }->{target};
        $logger->error( "Failed: ($group) $source => $target" );

        # there was an error during the transfer, reschedule
        # it at the end of the list
        $self->_mark_available( $group, $source );
        my $fail_count = $self->_mark_failed( $group, $target );
        if ( $fail_count >= $max_failures_of{ident $self} ) {
            $logger->fatal( "Error: giving up on ($group) $target" );
        } else {
            $self->_mark_remaining( $group, $target );
        }

        delete $data_of{ident $self}->{running}->{ $pid };
    }


    sub _has_available_server {
        my ( $self, $group ) = @_;
        return unless $data_of{ident $self}->{available};
        return unless $data_of{ident $self}->{available}->{ $group };
        return 1 if $data_of{ident $self}->{available}->{ $group }->[0];
    }

    sub _reserve_available_server {
        my ( $self, $group ) = @_;
        if ( $self->_has_remaining_server( $group ) ) {
            my $server = shift @{ $data_of{ident $self}->{available}->{ $group } };
            $logger->debug( "Reserving ($group) $server" );
            return $server;
        }
    }

    sub _has_remaining_server {
        my ( $self, $group ) = @_;
        return unless $data_of{ident $self}->{remaining};
        return unless $data_of{ident $self}->{remaining}->{ $group };
        return 1 if $data_of{ident $self}->{remaining}->{ $group }->[0];
    }

    sub _reserve_remaining_server {
        my ( $self, $group ) = @_;

        if ( $self->_has_remaining_server( $group ) ) {
            my $server = shift @{ $data_of{ident $self}->{remaining}->{ $group } };
            $logger->debug( "Reserving ($group) $server" );

            # delete remaining data structure as groups are completed
            unless ( scalar @{ $data_of{ident $self}->{remaining}->{ $group } } ) {
                $logger->debug( "Group empty: $group" );
                delete $data_of{ident $self}->{remaining}->{ $group };
                unless ( scalar ( keys %{ $data_of{ident $self}->{remaining} } ) ) {
                    $logger->debug( "No servers remaining" );
                    delete $data_of{ident $self}->{remaining};
                }
            }
            return $server;
        }
    }

    sub _get_remaining_groups {
        my ( $self ) = @_;
        return unless $data_of{ident $self}->{remaining};
        my @keys = keys %{ $data_of{ident $self}->{remaining} };
        return unless scalar @keys;
        return @keys;
    }

    sub _mark_available {
        my ( $self, $group, $server ) = @_;

        # don't reschedule localhost for future syncs
        return if $server eq "localhost";

        $logger->debug( "Server available: ($group) $server" );
        push @{ $data_of{ident $self}->{available}->{ $group } }, $server;
    }

    sub _mark_remaining {
        my ( $self, $group, $server ) = @_;

        $logger->debug( "Server remaining: ($group) $server" );
        push @{ $data_of{ident $self}->{remaining}->{ $group } }, $server;
    }

    sub _mark_completed {
        my ( $self, $group, $server ) = @_;

        $logger->debug( "Server completed: ($group) $server" );
        push @{ $data_of{ident $self}->{completed}->{ $group } }, $server;
    }

    sub _mark_failed {
        my ( $self, $group, $server ) = @_;

        $logger->debug( "Server completed: ($group) $server" );
        $data_of{ident $self}->{failed}->{ $group }->{ $server }++;
        my $failures = $data_of{ident $self}->{failed}->{ $group }->{ $server };
        $logger->debug( "$failures failures for ($group) $server" );
        return $failures;
    }

}


1;

__END__

=head1 NAME

Net::CascadeCopy - efficiently replicate files across many servers


=head1 SYNOPSIS

    use Net::CascadeCopy;

    # create a new CascadeCopy object
    my $ccp = Net::CascadeCopy->new( { ssh          => "/path/to/ssh",
                                       ssh_flags    => "-x -A",
                                       max_failures => 3,
                                       max_forks    => 2,
                                   } );

    # set the command and arguments to use to transfer file(s)
    $ccp->set_command( { command => "scp",
                         args    => "-p",
                     } );

    # set path on the local server
    $ccp->set_source_path( "/path/on/local/server" );
    # set path on all remote servers
    $ccp->set_source_path( "/path/on/remote/servers" );

    # add lists of servers in multiple datacenters
    $ccp->add_group( "datacenter1", \@dc1_servers );
    $ccp->add_group( "datacenter2", \@dc2_servers );

    # transfer all files
    $ccp->transfer();


=head1 DESCRIPTION

This module efficiently replicates a file or directory across a large
number of servers in multiple datacenters via rsync or scp.

The usual approach to copying a file to many servers is to copy it to
one or more central file servers and then copy it from there to every
other server in the datacenter.  The speed at which the file can be
copied is a function of the local cpu/disk utilization and the network
throughput on the file server(s).

This module takes a different approach.  Once a file has been copied
to a remote server, that server will then be used as a source point
for copying the file to additional servers.


=head1 CONSTRUCTOR

=over 8

=item C< new( ) >

Returns a reference to a new use Net::CascadeCopy object.

This is an inside-out perl class.  For more info, see "Perl Best
Practices" by Damian Conway

=back


=head1 INTERFACE


=over 8

=item C<$self->add_group( $groupname, \@servers )>

Add a group of servers.  Ideally all servers will be located in the
same datacenter.  This may be called multiple times with different
group names to create multiple groups.

=item C<$self->set_command( $command, $args )>

Set the command and arguments that will be used to transfer files.
For example, "rsync" and "-ravuz" could be used for rsync, or "scp"
and "-p" could be used for scp.

=item C<$self->set_source_path( $path )>

Specify the path on the local server where the source files reside.

=item C<$self->set_target_path( $path )>

Specify the target path on the remote servers where the files should
be copied.

=item C<$self->transfer( )>

Transfer all files.  Will not return until all files are transferred.

=back


=head1 BUGS AND LIMITATIONS

There are no known bugs in this module. Please report problems to
VVu@geekfarm.org

Patches are welcome.



=head1 AUTHOR

Alex White  C<< <vvu@geekfarm.org> >>




=head1 LICENCE AND COPYRIGHT

Copyright (c) 2007, Alex White C<< <vvu@geekfarm.org> >>. All rights reserved.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

- Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in the
  documentation and/or other materials provided with the distribution.

- Neither the name of the geekfarm.org nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.







