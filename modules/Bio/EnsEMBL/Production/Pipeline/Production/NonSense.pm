=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

package Bio::EnsEMBL::Production::Pipeline::Production::NonSense;

use strict;
use warnings;

use base qw/Bio::EnsEMBL::Production::Pipeline::Base/;


use Bio::EnsEMBL::Attribute;



sub run {
  my ($self) = @_;
  my $species = $self->param('species');
  my $dba        = Bio::EnsEMBL::Registry->get_DBAdaptor($species, 'core');
  my $dbva       = Bio::EnsEMBL::Registry->get_DBAdaptor($species, 'variation');

  my %codes = $self->get_attrib_codes();
  $self->delete_old_attribs($dba, %codes);

  my %unique;
  my $pops = $self->get_populations();
  my %pop_ids = $self->get_population_ids($dbva, $pops);
  my $transcripts = $self->get_features($dbva);
  foreach my $transcript (@{ $transcripts }) {
    my @transcript = @$transcript;
    if ($pop_ids{$transcript->[0]}) {
      my $pop = $pop_ids{$transcript->[0]};
      my $transcript_stable_id = $transcript->[1];
      my $rsid = $transcript->[2];
      my $consequence = $transcript->[3];
      print "FOUND:" . $transcript_stable_id . "\t" . $pop . "\t" . $rsid  . "\t" . $consequence . "\n";
      if (!$unique{$transcript_stable_id.":".$rsid.":".$pop.":".$consequence}) {
        $self->store_attribute($dbva, $transcript_stable_id, $rsid, $pop, $consequence, %codes); 
        $unique{$transcript_stable_id.":".$rsid.":".$pop.":".$consequence} = 1;
      }
    }
  }
}

sub store_attribute {
  my ($self, $dbva, $transcript_stable_id, $rsid, $pop, $consequence, %codes) = @_;
  my $aa = Bio::EnsEMBL::Registry->get_adaptor($self->param('species'), 'core', 'attribute');
  my $ta = Bio::EnsEMBL::Registry->get_adaptor($self->param('species'), 'core', 'transcript');
  my $transcript = $ta->fetch_by_stable_id($transcript_stable_id);
  my $code = $codes{$consequence};
  
  my $prod_dba    = $self->get_production_DBAdaptor();
  my $prod_helper = $prod_dba->dbc()->sql_helper();
  my $sql = q{
    SELECT name, description
    FROM attrib_type
    WHERE code = ? };
  my ($name, $description) = @{$prod_helper->execute(-SQL => $sql, -PARAMS => [$code])->[0]};
  my $attrib = Bio::EnsEMBL::Attribute->new(
    -NAME        => $name,
    -CODE        => $code,
    -VALUE       => $rsid.",".$pop,
    -DESCRIPTION => $description
  );
  my @attribs = ($attrib);
  if ($transcript) {
    $aa->store_on_Transcript($transcript, \@attribs);
  }
}


sub get_population_ids {
  my ($self, $dbva, $pops) = @_;
  my %pop_ids;
  my $helper = $dbva->dbc()->sql_helper();

  my ($population_id, $name);
  my $sql = q{
     SELECT population_id, name
     FROM population 
     WHERE name = ? };
  foreach my $pop (@$pops) {
    my $result = $helper->execute(-SQL => $sql, -PARAMS => [$pop])->[0] ;
    if ($result) {
      $population_id = @$result[0];
      $name = @$result[1];
    }
    if ($population_id) {
      $pop_ids{$population_id} = $name;
    }
  }
  return %pop_ids;
}

sub get_features {
  my ($self, $dbva) = @_;
  my $helper = $dbva->dbc->sql_helper();
  my $source_id = $self->get_source_id($dbva, 'dbSNP');
  
  if(!$source_id) {
    return [];
  }
  
  my $frequency = $self->param('frequency');
  my $observation = $self->param('observation');
  my $sql = q{
     SELECT a.population_id, tv.feature_stable_id, vf.variation_name, substring_index(tv.consequence_types, ",", 1)
     FROM transcript_variation tv, variation_feature vf, allele_code ac, allele a
     WHERE vf.variation_feature_id = tv.variation_feature_id
     AND vf.variation_id = a.variation_id
     AND ac.allele = substring_index(tv.allele_string, "/", -1)
     AND tv.somatic = 0
     AND (FIND_IN_SET('stop_lost', tv.consequence_types) 
     OR FIND_IN_SET('stop_gained', tv.consequence_types)) 
     AND a.allele_code_id = ac.allele_code_id
     AND substring_index(tv.consequence_types, ",", 1) IN ('stop_lost','stop_gained')
     AND a.frequency >= ?
     AND a.count >= ?
     AND vf.source_id = ? };
  my @transcripts =  @{ $helper->execute(-SQL => $sql, -PARAMS =>[$frequency, $observation, $source_id]) }  ;
  return \@transcripts;
}

sub delete_old_attribs {
  my ($self, $dba, %codes) = @_;
  my $helper = $dba->dbc()->sql_helper();
  my $sql = q{
     DELETE ta
     FROM transcript_attrib ta, attrib_type at
     WHERE ta.attrib_type_id = at.attrib_type_id
     AND at.code = ? };
  foreach my $code (keys %codes) {
    $helper->execute_update(-SQL => $sql, -PARAMS => [$code]);
  }
  $dba->dbc()->disconnect_if_idle();
}

sub get_source_id {
  my ($self, $dbva, $source) = @_;
  my $helper = $dbva->dbc()->sql_helper();
  my $sql = q{
     SELECT source_id
     FROM source
     WHERE name = ? };
  my ($source_id) = @{$helper->execute_simple(-SQL => $sql, -PARAMS => [$source])};
  return $source_id if $source_id;
  return;
}


sub get_attrib_codes {
  my ($self) = @_;
  my %attrib_codes = ('stop_lost' => 'StopLost', 'stop_gained' => 'StopGained');
  return %attrib_codes;
}

sub get_populations {
  my ($self) = @_;
  my @pops = (
    'CSHL-HAPMAP:HAPMAP-ASW',
    'CSHL-HAPMAP:HapMap-CEU',
    'CSHL-HAPMAP:HAPMAP-CHB',
    'CSHL-HAPMAP:HAPMAP-CHD',
    'CSHL-HAPMAP:HAPMAP-GIH',
    'CSHL-HAPMAP:HapMap-HCB',
    'CSHL-HAPMAP:HapMap-JPT',
    'CSHL-HAPMAP:HAPMAP-LWK',
    'CSHL-HAPMAP:HAPMAP-MEX',
    'CSHL-HAPMAP:HAPMAP-MKK',
    'CSHL-HAPMAP:HAPMAP-TSI',
    'CSHL-HAPMAP:HapMap-YRI',
    '1000GENOMES:phase_1_AFR',
    '1000GENOMES:phase_1_ALL',
    '1000GENOMES:phase_1_AMR',
    '1000GENOMES:phase_1_ASN',
    '1000GENOMES:phase_1_EUR',
    'ESP6500:African_American',
    'ESP6500:European_American',
  );
  return \@pops;
}


1;

