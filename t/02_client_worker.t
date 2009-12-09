#!perl

use strict;
use warnings;
use Test::Base;
use Test::TCP;
use Test::Deep;

use AnyEvent::Gearman::Client;
use AnyEvent::Gearman::Worker;

eval q{
        use Gearman::Worker;
        use Gearman::Server;
    };
if ($@) {
    plan skip_all
        => "Gearman::Worker and Gearman::Server are required to run this test";
}

plan 'no_plan';

my $port = empty_port;

sub run_tests {
    my $server_hostspec = '127.0.0.1:' . $port;

    my $client = AnyEvent::Gearman::Client->new(
        job_servers => [$server_hostspec],
    );

    my $worker = AnyEvent::Gearman::Worker->new(
        job_servers => [$server_hostspec],
    );
    $worker->register_function( reverse => sub {
        my $job = shift;
        my $res = reverse $job->workload;
        $job->complete($res);
    });

    for (1..2) {
	      my $cv = AnyEvent->condvar;
	      my $task = $client->add_task(
	          reverse => 'Hello!',
	          on_complete => sub {
	              $cv->send($_[1]);
	          },
	          on_fail => sub {
	              $cv->send('fail');
	          },
	          on_created => sub {
	              my ($task) = @_;
	              my $job_handle = $task->job_handle;
	              ok($job_handle, "Got JOB_CREATED message, got job_handle '$job_handle'");
	          }
	      );
	      ok(!$task->job_handle, 'No job_handle yet');

	      is $cv->recv, reverse('Hello!'), 'reverse ok';
    }

    ## Make sure context is sane
    $_->context && is($_->context, $worker) for @{$worker->job_servers};
    $_->context && is($_->context, $client) for @{$client->job_servers};

    # Test bg jobs
    my $cv = AnyEvent->condvar;
    $worker->register_function( bg_done => sub {
        my $job = shift;
        my $work = $job->workload;
        
        $job->complete($work);
        $cv->send("bg job done: $work");
    });
    
    my %cbs;
    $client->add_task_bg(
        bg_done => 'pick me!',
        
        on_created  => sub { $cbs{on_created}++  },
        on_data     => sub { $cbs{on_data}++     },
        on_status   => sub { $cbs{on_status}++   },
        on_warning  => sub { $cbs{on_warning}++  },
        on_complete => sub { $cbs{on_complete}++ },
        on_fail     => sub { $cbs{on_fail}++     },
    );
    
    is $cv->recv, 'bg job done: pick me!';
    cmp_deeply(\%cbs, { on_created => 1 }, 'proper set of callbacks executed');
}

my $child = fork;
if (!defined $child) {
    die "fork failed: $!";
}
elsif ($child == 0) {
    my $server = Gearman::Server->new( port => $port );
    Danga::Socket->EventLoop;
    exit;
}
else {
    END { kill 9, $child if $child }
}

sleep 1;

run_tests;

