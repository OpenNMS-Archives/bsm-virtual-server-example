#!/usr/bin/perl
# This script provides an example of how you can create a business
# service hierarchy using the REST API
#
# DISCLAIMER: In order to keep this script simple we mostly ignore
# input validation and error checking. We also include many
# hardcoded values.
#
use strict;
use warnings;
use REST::Client; # Provided by the perl-REST-Client package on Fedora 23
use JSON; # Provided by the perl-JSON package on Fedora 23
use URI::URL;
use Data::Dumper;
use MIME::Base64;
use Getopt::Long;

my $prefix = '';
my $vserver;
my @loadbalancers;
my @poolmembers;

GetOptions ('with-prefix=s' => \$prefix,
            'named=s' => \$vserver,
            'load-balanced-by=s@' => \@loadbalancers,
            'with-pool-member=s@' => \@poolmembers);

printf "Creating business services for virtual server: %s\n", $vserver;
printf "Load balanced by: %s\n", join(", ", @loadbalancers);
printf "With members: %s\n", join(", ", @poolmembers);

# Initialize our REST client
my $username = 'admin';
my $password = 'admin';
my $headers = {Accept => 'application/json', 'Content-Type' => 'application/json', Authorization => 'Basic ' . encode_base64($username . ':' . $password)};
my $client = REST::Client->new();
$client->setHost('http://localhost:8980');
my $json = JSON->new;

sub create_business_service {
  my ($name, $reduce_function) = @_;
  my $bsvc = {
    name => $prefix . $name,
    attributes => { },
    'ip-service-edges' => [ ],
    'reduction-key-edges' => [ ],
    'child-edges' => [],
    'reduce-function' => $reduce_function ? $reduce_function : {
      type => "HighestSeverity",
      properties => { }
    }
  };

  $client->POST(
      '/opennms/api/v2/business-services',
      $json->encode($bsvc),
      $headers
  );

  my $location = new URI::URL $client->responseHeader('Location');
  $client->GET(
    $location->full_path,
    $headers
  );
  return from_json($client->responseContent());
}

sub add_reduction_key_edge {
  my ($bsvc_id, $reduction_key) = @_;
  my $edge = {
    weight => 1,
    'map-function' => {
      'type' => 'Identity',
      'properties' => { }
    },
    'reduction-key' => $reduction_key
  };

  $client->POST(
      "/opennms/api/v2/business-services/$bsvc_id/reduction-key-edge",
      $json->encode($edge),
      $headers
  );
}

sub add_child_edge {
  my ($bsvc_id, $child_bsvc_id, $map_function) = @_;
  my $edge = {
    weight => 1,
    'map-function' => $map_function ? $map_function : {
      'type' => 'Identity',
      'properties' => { }
    },
    'child-id' => $child_bsvc_id
  };

  $client->POST(
      "/opennms/api/v2/business-services/$bsvc_id/child-edge",
      $json->encode($edge),
      $headers
  );
}

sub create_bsvc_for_redundant_service {
  my ($name, $members_ref, $reduction_keys_ref) = @_;
  my @members = @{ $members_ref };
  my @reduction_keys = @{ $reduction_keys_ref };

  # Create a business service for each member
  my @member_bsvc_ids = ();
  foreach my $member (@members) {
    my $bsvc = create_business_service($member);
    foreach my $reduction_key (@reduction_keys) {
      add_reduction_key_edge($bsvc->{'id'}, sprintf($reduction_key, $member));
    }
    push @member_bsvc_ids, $bsvc->{'id'};
  }

  # Create intermediary services with different thresholds
  my @intermediaries = (
    {name => 'All', threshold => '1.0', 'set-to' => 'Critical'},
    {name => 'Quorum', threshold => '0.5', 'set-to' => 'Major'},
    {name => 'Any', 'set-to' => 'Warning'}
  );

  my @intermediary_bsvc_ids = ();
  foreach my $intermediary (@intermediaries) {
    my $reduce = exists $intermediary->{'threshold'} ? {
      type => "Threshold",
      properties => {
        threshold => $intermediary->{'threshold'}
      }
    } : undef;

    my $bsvc = create_business_service($name . " " . $intermediary->{'name'}, $reduce);
    $intermediary->{'id'} = $bsvc->{'id'};

    # Add all of the members to each one of the intermediaries
    foreach my $member_bsvc_id (@member_bsvc_ids) {
      add_child_edge($bsvc->{'id'}, $member_bsvc_id);
    }
  }

  # Now create the top-level service to aggregate the results of the intermediaries
  my $members_bsvc = create_business_service($name);

  # Add all of the intermediaries to the top-level service
  foreach my $intermediary (@intermediaries) {
    my $map = exists $intermediary->{'set-to'} ? {
      type => "SetTo",
      properties => {
        status => $intermediary->{'set-to'}
      }
    } : undef;
    add_child_edge($members_bsvc->{'id'}, $intermediary->{'id'}, $map);
  }

  # We're done
  return $members_bsvc;
}

# Create a hierarchy for the pool members
my @poolmember_reduction_keys = (
  "uei.opennms.org/alarms/trigger:%s::lbHealthCheck",
  "uei.opennms.org/alarms/trigger:%s::nodeDown"
  );

my $poolmembers_bsvc = create_bsvc_for_redundant_service("Pool Members",
  \@poolmembers, \@poolmember_reduction_keys);

# Create a hierarchy for the load balancers
my @loadbalancer_reduction_keys = (
  "uei.opennms.org/alarms/trigger:%s::nodeDown"
  );

my $loadbalancers_bsvc = create_bsvc_for_redundant_service("Load Balancers",
  \@loadbalancers, \@loadbalancer_reduction_keys);

# Create a service for the virtual server
my $vserver_bsvc = create_business_service($vserver);

# Add the pool members, and load balancers as children
add_child_edge($vserver_bsvc->{'id'}, $poolmembers_bsvc->{'id'});
add_child_edge($vserver_bsvc->{'id'}, $loadbalancers_bsvc->{'id'});

# Add a reduction key
add_reduction_key_edge($vserver_bsvc->{'id'}, sprintf("uei.opennms.org/alarms/trigger:%s::serviceDown", $vserver));
