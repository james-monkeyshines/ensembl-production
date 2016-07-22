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

package Bio::EnsEMBL::Production::Pipeline::PipeConfig::FASTA_conf;

use strict;
use warnings;

use base ('Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf');

use Bio::EnsEMBL::ApiVersion qw/software_version/;

sub default_options {
    my ($self) = @_;
    
    return {
        # inherit other stuff from the base class
        %{ $self->SUPER::default_options() }, 
        
        ### OVERRIDE
        
        #'registry' => 'Reg.pm', # default option to refer to Reg.pm, should be full path
        #'base_path' => '', #where do you want your files
        
        ### Optional overrides        
        ftp_dir => '',

        # Species to run; use this to restrict to subset of species but be aware you
        # are still open to the reuse checks. If you do not want this then use
        # force_species
        species => [],
        
        # The types to emit
        dump_types => [],
        
        # The databases to emit (defaults to core)
        db_types => [],
        
        # Specify species you really need to get running
        force_species => [],
        
        # Only process these logic names
        process_logic_names => [],
        
        # As above but switched around. Do not process these names
        skip_logic_names => [],
        
        # The release of the data
        release => software_version(),
        
        # The previous release; override if running on something different
        previous_release => (software_version() - 1),
        
        run_all => 0, #always run every species

        ### Indexers
        skip_blat => 0,

        skip_wublast => 1,

        skip_ncbiblast => 0,

        skip_blat_masking => 1,

        skip_wublast_masking => 1,

        skip_ncbiblast_masking => 0,
        
        ### SCP code
        
        blast_servers => [],
        blast_genomic_dir => '',
        blast_genes_dir => '',
        
        scp_user => $self->o('ENV', 'USER'),
        scp_identity => '',
        no_scp => 0,
        
        ### Defaults 
        
        pipeline_name => 'fasta_dump_'.$self->o('release'),
        
        wublast_exe => 'xdformat',
        ncbiblast_exe => 'makeblastdb',
        blat_exe => 'faToTwoBit',
        
        email => $self->o('ENV', 'USER').'@sanger.ac.uk',
    };
}

sub pipeline_create_commands {
    my ($self) = @_;
    return [
      # inheriting database and hive tables' creation
      @{$self->SUPER::pipeline_create_commands}, 
    ];
}

## See diagram for pipeline structure 
sub pipeline_analyses {
    my ($self) = @_;
    
    return [
    
      {
        -logic_name => 'ScheduleSpecies',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::ReuseSpeciesFactory',
        -parameters => {
          species => $self->o('species'),
          sequence_type_list => $self->o('dump_types'),
          ftp_dir => $self->o('ftp_dir'),
          force_species => $self->o('force_species'),
          run_all => $self->o('run_all'),
        },
        -input_ids  => [ {} ],
        -flow_into  => {
          1 => 'Notify',
          2 => 'DumpDNA',
          3 => 'DumpGenes',
          4 => 'CopyDNA',
          5 => 'ChecksumGeneratorFactory'
        },
      },
      
      ######### DUMPING DATA
      
      {
        -logic_name => 'DumpDNA',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::DumpFile',
        -parameters => {
          process_logic_names => $self->o('process_logic_names'),
          skip_logic_names => $self->o('skip_logic_names'),
        },
        -can_be_empty => 1,
        -flow_into  => {
          1 => 'ConcatFiles'
        },
        -can_be_empty     => 1,
        -max_retry_count  => 1,
        -hive_capacity    => 10,
        -rc_name          => 'dump',
      },
      
      {
        -logic_name => 'DumpGenes',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::DumpFile',
        -parameters => {
          process_logic_names => $self->o('process_logic_names'),
          skip_logic_names => $self->o('skip_logic_names'),
        },
        -flow_into  => {
          2 => ['NcbiBlastPepIndex', 'BlastPepIndex'],
          3 => ['NcbiBlastGeneIndex', 'BlastGeneIndex']
        },
        -max_retry_count  => 1,
        -hive_capacity    => 10,
        -can_be_empty     => 1,
        -rc_name          => 'dump',
        -wait_for         => 'DumpDNA' #block until DNA is done
      },
      
      {
        -logic_name => 'ConcatFiles',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::ConcatFiles',
        -can_be_empty => 1,
        -max_retry_count => 5,
        -flow_into  => {
          1 => [qw/NcbiBlastDNAIndex BlastDNAIndex BlatDNAIndex PrimaryAssembly/]
        },
      },
      
      {
        -logic_name       => 'PrimaryAssembly',
        -module           => 'Bio::EnsEMBL::Production::Pipeline::FASTA::CreatePrimaryAssembly',
        -can_be_empty     => 1,
        -max_retry_count  => 5,
        -wait_for         => 'DumpDNA' #block until DNA is done
      },
      
      ######## COPY DATA
      
      {
        -logic_name => 'CopyDNA',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::CopyDNA',
        -can_be_empty => 1,
        -hive_capacity => 5,
        -parameters => {
          ftp_dir => $self->o('ftp_dir')
        },
      },
      
      ######## INDEXING
      
      {
        -logic_name => 'BlastDNAIndex',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::WuBlastIndexer',
        -parameters => {
          molecule => 'dna', type => 'genomic', program => $self->o('wublast_exe'), skip => $self->o('skip_wublast'),
          index_masked_files => $self->o('skip_wublast_masking'),
        },
        -hive_capacity => 10,
        -can_be_empty => 1,
        -rc_name => 'indexing',
      },
      
      {
        -logic_name => 'BlastPepIndex',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::WuBlastIndexer',
        -parameters => {
          molecule => 'pep', type => 'genes', program => $self->o('wublast_exe'), skip => $self->o('skip_wublast'),
        },
        -hive_capacity => 5,
        -can_be_empty => 1,
        -flow_into => {
          1 => [qw/SCPBlast/],
        },
      },
      
      {
        -logic_name => 'BlastGeneIndex',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::WuBlastIndexer',
        -parameters => {
          molecule => 'dna', type => 'genes', program => $self->o('wublast_exe'), skip => $self->o('skip_wublast'),
        },
        -hive_capacity => 5,
        -can_be_empty => 1,
        -flow_into => {
          1 => [qw/SCPBlast/],
        },
      },
      
      {
        -logic_name => 'BlatDNAIndex',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::BlatIndexer',
        -parameters => {
          program => $self->o('blat_exe'),
          'index' => 'dna',
          skip => $self->o('skip_blat'),
          index_masked_files => $self->o('skip_blat_masking'),
        },
        -can_be_empty => 1,
        -hive_capacity => 5,
        -rc_name => 'indexing',
      },

      {
        -logic_name => 'NcbiBlastDNAIndex',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::NcbiBlastIndexer',
        -parameters => {
          molecule => 'dna', 
          type => 'genomic', 
          program => $self->o('ncbiblast_exe'), 
          skip => $self->o('skip_ncbiblast'), 
          index_masked_files => $self->o('skip_ncbiblast_masking'),
        },
        -hive_capacity => 10,
        -can_be_empty => 1,
        -rc_name => 'indexing',
        # -flow_into => {
        #   1 => [qw/SCPBlast/],
        # },
      },
      
      {
        -logic_name => 'NcbiBlastPepIndex',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::NcbiBlastIndexer',
        -parameters => {
          molecule => 'pep', type => 'genes', program => $self->o('ncbiblast_exe'), skip => $self->o('skip_ncbiblast'),
        },
        -hive_capacity => 5,
        -can_be_empty => 1,
        # -flow_into => {
        #   1 => [qw/SCPBlast/],
        # },
      },
      
      {
        -logic_name => 'NcbiBlastGeneIndex',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::NcbiBlastIndexer',
        -parameters => {
          molecule => 'dna', type => 'genes', program => $self->o('ncbiblast_exe'), skip => $self->o('skip_ncbiblast'),
        },
        -hive_capacity => 5,
        -can_be_empty => 1,
        # -flow_into => {
        #   1 => [qw/SCPBlast/],
        # },
      },
      
      ######## COPYING
      {
        -logic_name => 'SCPBlast',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::SCPBlast',
        -parameters => {
          target_servers => $self->o('blast_servers'),
          genomic_dir => $self->o('blast_genomic_dir'),
          genes_dir => $self->o('blast_genes_dir'),
          
          scp_user => $self->o('scp_user'),
          scp_identity => $self->o('scp_identity'),
          
          no_scp => $self->o('no_scp'),
        },
        -hive_capacity => 3,
        -can_be_empty => 1,
        -wait_for => [qw/DumpDNA DumpGenes PrimaryAssembly BlastDNAIndex BlastGeneIndex BlastPepIndex/]
      },
      
      ####### CHECKSUMMING
      
      {
        -logic_name => 'ChecksumGeneratorFactory',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::FindDirs',
        -parameters => {
          column_names => [qw/dir/],
          fan_branch_code => 2,
        },
        -wait_for   => [qw/DumpDNA DumpGenes PrimaryAssembly BlastDNAIndex BlastGeneIndex BlastPepIndex/],
        -flow_into  => { 2 => {'ChecksumGenerator' => { dir => '#dir#'}} },
      },
      {
        -logic_name => 'ChecksumGenerator',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::ChecksumGenerator',
        -hive_capacity => 10,
      },
      
      ####### NOTIFICATION
      
      {
        -logic_name => 'Notify',
        -module     => 'Bio::EnsEMBL::Production::Pipeline::FASTA::EmailSummary',
        -parameters => {
          email   => $self->o('email'),
          subject => $self->o('pipeline_name').' has finished',
        },
        -wait_for   => ['SCPBlast', 'ChecksumGenerator'],
      }
    
    ];
}

sub pipeline_wide_parameters {
    my ($self) = @_;
    
    return {
        %{ $self->SUPER::pipeline_wide_parameters() },  # inherit other stuff from the base class
        base_path => $self->o('base_path'), 
        db_types => $self->o('db_types'),
        release => $self->o('release'),
        previous_release => $self->o('previous_release'),
    };
}

# override the default method, to force an automatic loading of the registry in all workers
sub beekeeper_extra_cmdline_options {
    my $self = shift;
    return "-reg_conf ".$self->o("registry");
}

sub resource_classes {
    my $self = shift;
    return {
      'dump'      => { LSF => '-q long -M1000 -R"select[mem>1000] rusage[mem=1000]"' },
      'indexing'  => { LSF => '-q normal -M3000 -R"select[mem>3000] rusage[mem=3000]"' },
    }
}

1;
