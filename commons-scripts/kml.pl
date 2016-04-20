#!/usr/bin/perl

use utf8;
use open ':utf8';
use Data::Dumper;
use XML::LibXML;

binmode STDOUT, ":encoding(UTF-8)";

my $parser = XML::LibXML->new();

my $f = $parser->parse_file('x.kml') or die;

$rootel = $f -> getDocumentElement();

#&dodo($rootel);
process_node($rootel);


sub process_node {
  my $node = shift;

#  print $node->nodePath, "\n";
#  print $node->getName . " " . $node->getValue . "\n";
  if ($node->getName eq "Placemark") {
    my %h;
    for my $child ($node->childNodes) {
      $n = $child->getName;
      $v = $child->textContent;
      $v =~ s/[\n\t]//g;
      $v =~ s/^\s+|\s+$//g;
      $h{$n} = $v;
    }

    my ($lon,$lat) = split(/,/, $h{Point});

    $query = "insert into commons (id, lat, lon, name, desc) values (null, '$lat', '$lon', '$h{name}', '$h{description}');";

    print "$query\n";
  } else {
    for my $child ($node->childNodes) {
        process_node($child);
    }
  }
}


