#!/usr/bin/perl
# This script can be used to delete all of the business services
# on an OpenNMS instance
use strict;
use warnings;
use REST::Client; # Provided by the perl-REST-Client package on Fedora 23
use JSON; # Provided by the perl-JSON package on Fedora 23
use URI::URL;
use MIME::Base64;
use Getopt::Long;

# Initialize our REST client
my $username = 'admin';
my $password = 'admin';
my $headers = {Accept => 'application/json', 'Content-Type' => 'application/json', Authorization => 'Basic ' . encode_base64($username . ':' . $password)};
my $client = REST::Client->new();
$client->setHost('http://localhost:8980');
my $json = JSON->new;

# List all business services
$client->GET(
  '/opennms/api/v2/business-services',
  $headers
);

if ($client->responseCode() == 204) {
  print "The list of business services is already empty.\n";
  exit(0);
}

# Issue a delete for each of the entry
foreach my $bsvc (@{from_json($client->responseContent())->{'business-services'}}) {
  print "Deleting ${bsvc}...\n";
  $client->DELETE(
    '/opennms' . $bsvc,
    $headers
  );
  print $client->responseCode() . "\n";
}
