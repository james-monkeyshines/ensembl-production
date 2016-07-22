=pod 

=head1 NAME

Bio::EnsEMBL::Production::Pipeline::PostCompara::ProjectionBase

=cut

=head1 DESCRIPTION

=head1 MAINTAINER

$Author: ckong $

=cut
package Bio::EnsEMBL::Production::Pipeline::PostCompara::ProjectionBase;

use strict;
use warnings;
use Data::Dumper;
use Bio::EnsEMBL::Registry;
use Bio::EnsEMBL::DBSQL::TaxonomyNodeAdaptor;
use Bio::EnsEMBL::Utils::SqlHelper;
use Bio::EnsEMBL::Attribute;
use base ('Bio::EnsEMBL::Compara::RunnableDB::BaseRunnable');

=head2 fetch_homologies 

  Fetch the homologies from the Compara database. 
  Returns a hash of arrays:
  # Key = "from" stable ID, value = array of "to" stable IDs

=cut
sub fetch_homologies {
    my $self         = shift;
    my $ha           = shift;
    my $mlss         = shift;
    my $from_species = shift;
    my $data         = shift;
    my $gdba         = shift;
    my $homology_types_allowed = shift;
    my $percent_id_filter      = shift;

    print $data "\t\tFetching Compara homologies...";
    my $from_species_alias = $gdba->fetch_by_registry_name($from_species)->name();
    my %homology_cache;
    my $count              = 0;
    my $homologies         = $ha->fetch_all_by_MethodLinkSpeciesSet($mlss);

    foreach my $homology (@{$homologies}) {
       next if (!homology_type_allowed($homology->description, $homology_types_allowed));

       my ($from_stable_id, @to_stable_ids, @perc_id);
       my $members = $homology->get_all_GeneMembers();
       my $mems    = $homology->get_all_Members();
   
       foreach my $mem (@{$mems}){
           push @perc_id,$mem->perc_id();
       }
       next if (grep {$_ < $percent_id_filter} @perc_id) ;

       foreach my $member (@{$members}) {
         if ($member->genome_db()->name() eq $from_species_alias) {
            $from_stable_id = $member->stable_id();
         }
         else {
            push(@to_stable_ids, $member->stable_id());
         }
       }

       print STDERR "Warning: can't find stable ID corresponding to 'from' species ($from_species_alias)\n" if (!$from_stable_id);
       push @{$homology_cache{$from_stable_id}}, @to_stable_ids;
       $count++;
   }
   print $data "\tFetched " . $count . " homologies\n";

return \%homology_cache;
}

=head2 homology_type_allowed

  
=cut
sub homology_type_allowed {
    my $h                      = shift;
    my $homology_types_allowed = shift;

    foreach my $allowed (@$homology_types_allowed) {
      return 1 if ($h eq $allowed);
    }

return undef;
}

=head2 get_taxon_ancestry

  
=cut
sub get_taxon_ancestry {
    my $self        = shift;
    my $to_taxon_id = shift;

    my $dba =  Bio::EnsEMBL::DBSQL::DBAdaptor->new(
        -user   => 'ensro',
        -dbname => 'ncbi_taxonomy',
        -host   => 'mysql-eg-mirror.ebi.ac.uk',
        -port   => '4205');

    my $node_adaptor = Bio::EnsEMBL::DBSQL::TaxonomyNodeAdaptor->new($dba);
    my $node         = $node_adaptor->fetch_by_taxon_id($to_taxon_id);
    my @lineage      = @{$node_adaptor->fetch_ancestors($node)};
    my @ancestors;
    my @names;
    push @ancestors, $to_taxon_id;

    for my $node (@lineage) {
       push @ancestors, $node->taxon_id();
       push @names, $node->names()->{'scientific name'}->[0];
       #print STDERR  "\t\tNode ".$node->taxon_id()." is ".$node->rank()." ".$node->names()->{'scientific name'}->[0]."\n";
    }

return (\@ancestors,\@names);
}

=head2 check_directory

  
=cut
sub check_directory {
    my ($self, $dir) = @_;

    unless (-e $dir) {
        print STDERR "$dir doesn't exists. I will try to create it\n" if ($self->debug());
        print STDERR "mkdir $dir (0755)\n" if ($self->debug());
        die "Impossible create directory $dir\n" unless (mkdir $dir, 0755 );
    }

return;
}

=head2 backup

  
=cut
sub backup {
    my $self  = shift;
    my $to_ga = shift; 

    print STDERR "Back up tables 'gene','transcript','xref','object_xref','external_synonym'\n";

    my $helper = Bio::EnsEMBL::Utils::SqlHelper->new( -DB_CONNECTION => $to_ga->dbc() );

    $helper->execute_update(-SQL => 'drop table if exists gene_preProj_backup');
    $helper->execute_update(-SQL => 'drop table if exists transcript_preProj_backup');
    $helper->execute_update(-SQL => 'drop table if exists xref_preProj_backup');
    $helper->execute_update(-SQL => 'drop table if exists object_xref_preProj_backup');
    $helper->execute_update(-SQL => 'drop table if exists external_synonym_preProj_backup');

    $helper->execute_update(-SQL => 'create table gene_preProj_backup             like gene');
    $helper->execute_update(-SQL => 'create table transcript_preProj_backup       like transcript');
    $helper->execute_update(-SQL => 'create table xref_preProj_backup             like xref');
    $helper->execute_update(-SQL => 'create table object_xref_preProj_backup      like object_xref');
    $helper->execute_update(-SQL => 'create table external_synonym_preProj_backup like external_synonym');

    $helper->execute_update(-SQL => 'insert into gene_preProj_backup             select * from gene');
    $helper->execute_update(-SQL => 'insert into transcript_preProj_backup       select * from transcript');
    $helper->execute_update(-SQL => 'insert into xref_preProj_backup             select * from xref');
    $helper->execute_update(-SQL => 'insert into object_xref_preProj_backup      select * from object_xref');
    $helper->execute_update(-SQL => 'insert into external_synonym_preProj_backup select * from external_synonym');

return 0;
}

=head2 delete_go_terms

=cut
sub delete_go_terms {
    my $self  = shift;
    my $to_ga = shift;

    print STDERR "Delete existing projected GO terms in core\n";

    my $sql_del_terms = "DELETE x, ox, gx FROM xref x, external_db e, object_xref ox, ontology_xref gx WHERE x.xref_id=ox.xref_id AND x.external_db_id=e.external_db_id AND ox.object_xref_id=gx.object_xref_id AND e.db_name='GO' AND x.info_type='PROJECTION'";

    my $helper = Bio::EnsEMBL::Utils::SqlHelper->new( -DB_CONNECTION => $to_ga->dbc());
    $helper->execute_update(-SQL => $sql_del_terms);

    # note don't need to delete synonyms as GO terms don't have any
    # Also no effect on descriptions or status

return 0;
}

=head2 delete_gene_names

=cut
sub delete_gene_names {
    my $self  = shift;
    my $to_ga = shift;

    print STDERR "Setting projected transcript statuses to NOVEL\n";

    my $sql_del_terms = "UPDATE gene g, xref x, transcript t SET t.display_xref_id = NULL, t.description = NULL, t.status='NOVEL' WHERE g.display_xref_id=x.xref_id AND x.info_type='PROJECTION' AND g.gene_id = t.gene_id";

    my $helper = Bio::EnsEMBL::Utils::SqlHelper->new( -DB_CONNECTION => $to_ga->dbc());
    $helper->execute_update(-SQL => $sql_del_terms);

    print STDERR "Setting gene display_xrefs that were projected to NULL and status to NOVEL\n\n";

    $sql_del_terms = "UPDATE gene g, xref x SET g.display_xref_id = NULL, g.status='NOVEL' WHERE g.display_xref_id=x.xref_id AND x.info_type='PROJECTION'";

    $helper->execute_update(-SQL => $sql_del_terms);

    print STDERR "Deleting projected xrefs, object_xrefs and synonyms\n";

    $sql_del_terms = "DELETE es FROM xref x, external_synonym es WHERE x.xref_id=es.xref_id AND x.info_type='PROJECTION'";

    $helper->execute_update(-SQL => $sql_del_terms);

    $sql_del_terms="DELETE x, ox FROM xref x, object_xref ox, external_db e WHERE x.xref_id=ox.xref_id AND x.external_db_id=e.external_db_id AND x.info_type='PROJECTION' AND e.db_name!='GO'";

    $helper->execute_update(-SQL => $sql_del_terms);

return 0;
}

=head2 delete_gene_desc

=cut
sub delete_gene_desc {
    my $self  = shift;
    my $to_ga = shift;

    print STDERR "Setting descriptions that were projected to NULL \n";

    my $sql_del_terms = "UPDATE gene g, xref x SET g.description=NULL WHERE g.display_xref_id=x.xref_id AND x.info_type='PROJECTION'";
    
    my $helper = Bio::EnsEMBL::Utils::SqlHelper->new( -DB_CONNECTION => $to_ga->dbc());
    $helper->execute_update(-SQL => $sql_del_terms);

return 0;
}

=head2 print_GOstats

  
=cut
sub print_GOstats {
    my $self   = shift;
    my $to_ga  = shift;
    my $data   = shift;
 
    my $total_genes = count_rows($to_ga, "SELECT COUNT(*) FROM gene g");
    my $count;
    print $data "\tUnique GO terms total:";
    print $data &count_rows($to_ga, "SELECT COUNT(DISTINCT(x.dbprimary_acc)) FROM xref x, external_db e WHERE e.external_db_id=x.external_db_id AND e.db_name='GO'");
    print $data " Unique GO terms from projection:";
    print $data &count_rows($to_ga, "SELECT COUNT(DISTINCT(x.dbprimary_acc)) FROM xref x, external_db e WHERE e.external_db_id=x.external_db_id AND e.db_name='GO' AND x.info_type='PROJECTION'");
    print $data "\n\n";

return 0;
}

=head2 count_rows

  
=cut
sub count_rows {
    my ($adaptor, $sql) = @_;

    my $sth = $adaptor->dbc->prepare($sql);
    $sth->execute();

return ($sth->fetchrow_array())[0];
}

sub process_cigar_line {
    my $self    = shift;
    my $cigars  = shift;
    my $root_id = shift;

    my $sequence = 0;
    my (@hits, @misses);

    ## parse cigar strings into hit/miss matrix
    for my $x (@$cigars) {
        my ($id, $species, $cigar) = split '\^\^', $x;  
        my $position = 0;
 
        while (length $cigar > 0) {
          my ($number, $letter) = ($cigar =~ /^(\d*)(\w)/);
          $number = 1 if ($number eq ''); 

          for (my $i = 0; $i < $number; $i++) {
            if ($letter eq 'D') {
              $misses[$position][$sequence] = 1;
              $hits  [$position][$sequence] = 0;
            } else {
              $hits[$position][$sequence]   = 1;
              $misses[$position][$sequence] = 0;
            }
           $position++;
         }
         $cigar =~ s/^\d*\w//;
      }# while (length 
      $sequence++;
    } #for my $x

    my @profile;
    my $positions = scalar @hits;

    if ($positions == 0) {
      #print $lastRootId, "\n";
      print STDERR Dumper @hits,   "\n";
      print STDERR Dumper @misses, "\n";
    }

    ## Summing up the hits & misses count on each position
    ## for all sequences
    for (my $i = 0; $i < $positions; $i++) {
        my $hits   = 0;
        my $misses =0;
      
        for my $sequence (@{$hits[$i]}) {
            if ($hits[$i][$sequence] == 1){ $hits++; } 
            elsif ($misses[$i][$sequence] == 1){ $misses++; } 
            else { print STDERR join "*", 
	           #$lastRootId, 
	           $positions, scalar @hits, $i, $sequence, $hits[$i][$sequence], $misses[$i][$sequence], "\n";
                   die; # asusmptions of code are false
            }
       } #for my $sequence
      
      ## Summarize hits & misses count into consensus profile for each position      
      if ($hits >= $misses) { $profile[$i] = 1; } 
      else { $profile[$i] = 0; }
    } # for (my $i=0

    if (! defined @{$hits[0]}) {
       print STDERR "Problem for root ID: $root_id\n";
       print Dumper @hits;
       print "**\n";
       print Dumper @misses;
       die;
    }

    ## For each sequence derive score
    for (my $i = 0; $i < scalar @{$hits[0]}; $i++) {
        my $match = 0; my $unmatched = 0;
        my $extra = 0; my $wc = 0;

        ## Compare each position hit/miss matrix against the consensus profile
        for (my $j = 0; $j < scalar @hits; $j ++) {
          if ($hits[$j][$i] == $profile[$j]) {
             if ($profile[$j] == 1) { $match++; } 
             else { $wc++; }
          } else {
	     # profile is positive, protein is zero
             if ($profile[$j] == 1) { $unmatched++; }
             # profile is negative, protein is positve
	     else { $extra++; }
	  }
        } # for (my $j

      ## Derive scores for each sequence
      my ($id, $species, $cigar) = split '\^\^', @$cigars[$i];
      my $score1       = $match / ($match + $extra);
      # score 2: proportion of true positives, could be 0/0!
      my $score2;
      
      if ($match + $unmatched == 0) {
      	 print STDERR "Root ID: $root_id has no concensus positives\n";
      	 $score2 = 0;
      } else { $score2 = $match / ($match + $unmatched); }

      store_gene_attrib($id, $species, $score1, $score2);

    } # for ( my $i 

return 0;
}

sub store_gene_attrib {
    my ($id, $species, $score1, $score2) = @_; 

    my $gene_adaptor   = Bio::EnsEMBL::Registry->get_adaptor($species  , 'core', 'Gene');
    my $db_adaptor     = Bio::EnsEMBL::Registry->get_DBAdaptor($species, 'core');
    my $attrib_adaptor = $db_adaptor->get_AttributeAdaptor();
    my $gene           = $gene_adaptor->fetch_by_translation_stable_id($id);
    my @attribs;

    my $attrib1 = Bio::EnsEMBL::Attribute->new(
                -CODE        => 'prot_coverage',
                -NAME        => 'Protein Coverage',
                -DESCRIPTION => 'Protein coverage for this gene derived from checkAlignment2.pl script',
                -VALUE       => $score1);

    my $attrib2 = Bio::EnsEMBL::Attribute->new(
                -CODE        => 'con_coverage',
                -NAME        => 'Consensus Coverage',
                -DESCRIPTION => 'Consensus coverage for this gene derived from checkAlignment2.pl script',
                -VALUE       => $score2);
   
    push @attribs, $attrib1;
    push @attribs, $attrib2;

    $attrib_adaptor->store_on_Gene($gene, \@attribs);
    # $gene->add_Attributes($attrib1);
    # $gene->add_Attributes($attrib2);
    # my @gene_attributes = @{$gene->get_all_Attributes };
    print STDERR "$id\t$species\tscore1:$score1\tscore2:$score2\n";

return 0;
}

sub print_2d {
	my @array_2d=@_;

        # for the same position of each sequence
	for(my $i = 0; $i <= $#array_2d; $i++){
	   print STDERR "i-POSITION:$i\n";	

	   for(my $j = 0; $j <= $#{$array_2d[0]} ; $j++){
	      print STDERR "j-SEQUENCE COUNT:$j\n";	
	      print STDERR "$array_2d[$i][$j]\n";
	   }
	   print STDERR "\n";
	}
}


1;
