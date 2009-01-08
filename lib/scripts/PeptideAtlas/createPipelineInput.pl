#!/usr/local/bin/perl -w
###############################################################################
# Program     : createPipelineInput.pl
# Author      : Eric Deutsch <edeutsch@systemsbiology.org>
# $Id$
#
# Description : This script builds the input files needed for the PeptideAtlas
#               pipeline from a list of input samples and directories
#
# SBEAMS is Copyright (C) 2000-2005 Institute for Systems Biology
# This program is governed by the terms of the GNU General Public License (GPL)
# version 2 as published by the Free Software Foundation.  It is provided
# WITHOUT ANY WARRANTY.  See the full description of GPL terms in the
# LICENSE file distributed with this software.
#
###############################################################################

use strict;
use POSIX;  #for floor()
use Getopt::Long;
use XML::Xerces;
use FindBin;
use Data::Dumper;
use lib "$FindBin::Bin/../../perl";

use vars qw ($sbeams $sbeamsMOD $q
             $PROG_NAME $USAGE %OPTIONS $QUIET $VERBOSE $DEBUG $TESTONLY
             $DATABASE $current_contact_id $current_username
            );

use vars qw (%peptide_accessions %biosequence_attributes);

use SBEAMS::Connection;
use SBEAMS::Connection::Settings;
use SBEAMS::Connection::Tables;
use SBEAMS::Connection::TableInfo;

use SBEAMS::Proteomics::Tables;
use SBEAMS::PeptideAtlas::Tables;

$sbeams = new SBEAMS::Connection;


###############################################################################
# Read and validate command line args
###############################################################################
my $VERSION = q[$Id$ ];
$PROG_NAME = $FindBin::Script;

my $USAGE = <<EOU;
USAGE: $PROG_NAME [OPTIONS] source_file
Options:
  --verbose n         Set verbosity level.  default is 0
  --quiet             Set flag to print nothing at all except errors
                      This masks the printing of progress information
  --debug n           Set debug level.  default is 0
  --testonly          If set, nothing is actually inserted into the database,
                      but we just go through all the motions.  Use --verbose
                      to see all the SQL statements that would occur

  --validate=XXXXX    XML validation scheme [always | never | auto]
  --namespaces        Enable namespace processing. Defaults to off.
  --schemas           Enable schema processing. Defaults to off.

  --source_file       Input file containing the sample and directory listing
  --search_batch_ids  Comma-separated list of SBEAMS-Proteomics seach_batch_ids
  --P_threshold       Probability threshold to accept (e.g. 0.9)
  --output_file       Filename to which to write the peptides
  --master_ProteinProphet_file       Filename for a master ProteinProphet
                      run that should be used instead of individual ones
  --biosequence_set_id   Database id of the biosequence_set from which to load sequence attributes.
  --best_probs_from_protxml   Get best initial probs from ProteinProphet file,
                      not from pepXML files. Use when not using iProphet; faster.


 e.g.:  $PROG_NAME --verbose 2 --source YeastInputExperiments.tsv

EOU


#### If no parameters are given, print usage information
unless ($ARGV[0]){
  print "$USAGE";
  exit;
}


#### Process options
unless (GetOptions(\%OPTIONS,"verbose:s","quiet","debug:s","testonly",
  "validate=s","namespaces","schemas",
  "source_file:s","search_batch_ids:s","P_threshold:f","output_file:s",
  "master_ProteinProphet_file:s","biosequence_set_id:s",
  "best_probs_from_protxml",
  )) {
  print "$USAGE";
  exit;
}


$VERBOSE = $OPTIONS{"verbose"} || 0;
$QUIET = $OPTIONS{"quiet"} || 0;
$DEBUG = $OPTIONS{"debug"} || 0;
$TESTONLY = $OPTIONS{"testonly"} || 0;
if ($DEBUG) {
  print "Options settings:\n";
  print "  VERBOSE = $VERBOSE\n";
  print "  QUIET = $QUIET\n";
  print "  DEBUG = $DEBUG\n";
  print "  TESTONLY = $TESTONLY\n";
}


#### Get the search_batch_id parameter
my $source_file = $OPTIONS{source_file} || '';
my $APDTsvFileName = $OPTIONS{output_file} || '';
my $search_batch_ids = $OPTIONS{search_batch_ids} || '';
my $bssid = $OPTIONS{biosequence_set_id} || "10" ; ## some ISB default?



#### Make sure either --source_file or --search_batch_ids was specified
unless ($source_file || $search_batch_ids) {
  print "ERROR: You must specify either --source_file or --search_batch_ids\n";
  print "$USAGE";
  exit 0;
}


#### If source_file was specified, verify it
if ($source_file) {

  #### Check to make sure the file exists
  unless (-f $source_file) {
    die "File '$source_file' does not exist!\n";
  }

}


#### Process parser options
my $validate = $OPTIONS{validate} || 'never';
my $namespace = $OPTIONS{namespaces} || 0;
my $schema = $OPTIONS{schemas} || 0;
my $best_probs_from_protxml = $OPTIONS{best_probs_from_protxml} || 0;


if (uc($validate) eq 'ALWAYS') {
  $validate = $XML::Xerces::SAX2XMLReader::Val_Always;
} elsif (uc($validate) eq 'NEVER') {
  $validate = $XML::Xerces::SAX2XMLReader::Val_Never;
} elsif (uc($validate) eq 'AUTO') {
  $validate = $XML::Xerces::SAX2XMLReader::Val_Auto;
} else {
  die("Unknown value for -v: $validate\n$USAGE");
}


#### main package continues below after MyContentHandler package



###############################################################################
###############################################################################
###############################################################################
# MyContentHandler package: SAX parser callback routines
#
# This MyContentHandler package defines all the content handling callback
# subroutines used the SAX parser
###############################################################################
package MyContentHandler;
use strict;
use Date::Manip;
use vars qw(@ISA $VERBOSE);
@ISA = qw(XML::Xerces::PerlContentHandler);
$VERBOSE = 0;


###############################################################################
# new
###############################################################################
sub new {
  my $class = shift;
  my $self = $class->SUPER::new();
  $self->object_stack([]);
  $self->unhandled({});
  return $self;
}


###############################################################################
# object_stack
###############################################################################
sub object_stack {
  my $self = shift;
  if (scalar @_) {
    $self->{OBJ_STACK} = shift;
  }
  return $self->{OBJ_STACK};
}


###############################################################################
# setVerbosity
###############################################################################
sub setVerbosity {
  my $self = shift;
  if (scalar @_) {
    $VERBOSE = shift;
  }
}


###############################################################################
# unhandled
###############################################################################
sub unhandled {
  my $self = shift;
  if (scalar @_) {
    $self->{UNHANDLED} = shift;
  }
  return $self->{UNHANDLED};
}


###############################################################################
# start_element
###############################################################################
sub start_element {
  my ($self,$uri,$localname,$qname,$attrs) = @_;

  if ($self->{document_type} eq 'pepXML') {
    pepXML_start_element(@_);
  } elsif ($self->{document_type} eq 'protXML') {
    protXML_start_element(@_);
  } else {
    die("ERROR: Unknown document_type '$self->{document_type}'");
  }

  return(1);
}


###############################################################################
# pepXML_start_element
###############################################################################
sub pepXML_start_element {
  my ($self,$uri,$localname,$qname,$attrs) = @_;


  #### Make a hash to of the attributes
  my %attrs = $attrs->to_hash();

  #### Convert all the values from hashref to single value
  while (my ($aa1,$aa2) = each (%attrs)) {
    $attrs{$aa1} = $attrs{$aa1}->{value};
  }

  #### If this is a spectrum, then store some attributes
  if ($localname eq 'spectrum_query') {
    $self->{pepcache}->{spectrum} = $attrs{spectrum};
    $self->{pepcache}->{charge} = $attrs{assumed_charge};
  }

  #### If this is the search_hit, then store some attributes
  #### Note that this whole logic will break if there's more than one
  #### search_hit, which shouldn't be true so far
  if ($localname eq 'search_hit') {
    die("ERROR: Multiple search_hits not yet supported!")
      if (exists($self->{pepcache}->{peptide}));
    $self->{pepcache}->{peptide} = $attrs{peptide};
    $self->{pepcache}->{peptide_prev_aa} = $attrs{peptide_prev_aa};
    $self->{pepcache}->{peptide_next_aa} = $attrs{peptide_next_aa};
    $self->{pepcache}->{protein_name} = $attrs{protein};
    $self->{pepcache}->{massdiff} = $attrs{massdiff};
  }


  #### If this is the mass mod info, then store some attributes
  if ($localname eq 'modification_info') {
    if ($attrs{mod_nterm_mass}) {
      $self->{pepcache}->{modifications}->{0} = $attrs{mod_nterm_mass};
    }
    if ($attrs{mod_cterm_mass}) {
      my $pos = length($self->{pepcache}->{peptide})+1;
      $self->{pepcache}->{modifications}->{$pos} = $attrs{mod_cterm_mass};
    }
  }


  #### If this is the mass mod info, then store some attributes
  if ($localname eq 'mod_aminoacid_mass') {
    $self->{pepcache}->{modifications}->{$attrs{position}} = $attrs{mass};
  }


  #### If this is the search score info, then store some attributes
  if ($localname eq 'search_score') {
    $self->{pepcache}->{scores}->{$attrs{name}} = $attrs{value};
  }


  #### If this is the Peptide Prophet derived values, store some attributes
  if ($localname eq 'parameter') {
    $self->{pepcache}->{scores}->{$attrs{name}} = $attrs{value};
  }

  #### If this is the peptideProphet probability score, store some attributes
  if ($localname eq 'peptideprophet_result') {
    $self->{pepcache}->{scores}->{probability} = $attrs{probability};
  }

  ### If this is the iProphet probability score, store the probability
  ### Since iProphet tag comes after peptideProphet tag, this will
  ### supercede the peptideProphet probability. But this is kludgy
  ### and wrong -- shouldn't rely on order of tags.
  if ($localname eq 'interprophet_result') {
    $self->{pepcache}->{scores}->{probability} = $attrs{probability};
  }

  #### Push information about this element onto the stack
  my $tmp;
  $tmp->{name} = $localname;
  push(@{$self->object_stack},$tmp);


} # end pepXML_start_element



###############################################################################
# protXML_start_element
###############################################################################
sub protXML_start_element {
  my ($self,$uri,$localname,$qname,$attrs) = @_;

  #### Make a hash to of the attributes
  my %attrs = $attrs->to_hash();

  #### Convert all the values from hashref to single value
  while (my ($aa1,$aa2) = each (%attrs)) {
    $attrs{$aa1} = $attrs{$aa1}->{value};
  }

  #### If this is a protein, then store its name
  if ($localname eq 'protein') {
    $self->{protein_name} = $attrs{protein_name};
  }


  #### If this is the mass mod info, then store some attributes
  if ($localname eq 'modification_info') {
    if ($attrs{mod_nterm_mass}) {
      $self->{pepcache}->{modifications}->{0} = $attrs{mod_nterm_mass};
    }
    if ($attrs{mod_cterm_mass}) {
      my $pos = length($self->{pepcache}->{peptide})+1;
      $self->{pepcache}->{modifications}->{$pos} = $attrs{mod_cterm_mass};
    }
  }


  #### If this is the mass mod info, then store some attributes
  if ($localname eq 'mod_aminoacid_mass') {
    $self->{pepcache}->{modifications}->{$attrs{position}} = $attrs{mass};
  }


  #### If this is a peptide, then store some attributes
  if ($localname eq 'peptide') {
    my $peptide_sequence = $attrs{peptide_sequence} || die("No sequence");
    $self->{pepcache}->{peptide} = $attrs{peptide_sequence};
    $self->{pepcache}->{charge} = $attrs{charge};
    $self->{pepcache}->{initial_probability} = $attrs{initial_probability};
    $self->{pepcache}->{nsp_adjusted_probability} = $attrs{nsp_adjusted_probability};
    $self->{pepcache}->{n_sibling_peptides} = $attrs{n_sibling_peptides};
    $self->{pepcache}->{n_instances} = $attrs{n_instances};
  }


  #### If this pepetide has an indistinguishable twin, record it
  if ($localname eq 'indistinguishable_peptide') {
    my $peptide_sequence = $attrs{peptide_sequence} || die("No sequence");
    $self->{pepcache}->{indistinguishable_peptides}->{$peptide_sequence} = 1;
  }


  #### Push information about this element onto the stack
  my $tmp;
  $tmp->{name} = $localname;
  push(@{$self->object_stack},$tmp);


  #### Increase the counters and print some progress info
  #$self->{counter}++;
  #print $self->{counter}."..." if ($self->{counter} % 100 == 0);

} # end protXML_start_element



###############################################################################
# end_element
###############################################################################
sub end_element {
  my ($self,$uri,$localname,$qname) = @_;

  if ($self->{document_type} eq 'pepXML') {
    pepXML_end_element(@_);
  } elsif ($self->{document_type} eq 'protXML') {
    protXML_end_element(@_);
  } else {
    die("ERROR: Unknown document_type '$self->{document_type}'");
  }

  return(1);
}



###############################################################################
# pepXML_end_element
###############################################################################
sub pepXML_end_element {
  my ($self,$uri,$localname,$qname) = @_;

  #### If this is the end of the spectrum_query, store the information if it
  #### passes the threshold
  if ($localname eq 'spectrum_query') {
    my $peptide_sequence = $self->{pepcache}->{peptide};

    my $probability;
    if ($peptide_sequence) {
      $probability = $self->{pepcache}->{scores}->{probability};
    } else {
      #die("ERROR: No peptide sequence in the cache!");
      print "WARNING: No search result for this query!\n";
      $probability = -1;
    }


    #### If this peptide passes the threshold, store it
    #if ($probability >= $self->{P_threshold}) {
    # 10/08: iProphet may significantly increase the probability
    #    we don't want to discard anything that might ultimately be
    #    > P_threshold, so we are conservative and use 0.50 here.
    if ($probability > 0.50) {

      #### Create the modified peptide string
      my $modified_peptide = '';
      my $modifications = $self->{pepcache}->{modifications};
      if ($modifications) {
	my $i = 0;
	if ($modifications->{$i}) {
	  $modified_peptide .= 'n['.int($modifications->{$i}).']';
	}
	for ($i=1; $i<=length($peptide_sequence); $i++) {
	  my $aa = substr($peptide_sequence,$i-1,1);
	  if ($modifications->{$i}) {
	    $aa .= '['.int($modifications->{$i}).']';
	  }
	  $modified_peptide .= $aa;
	}
	if ($modifications->{$i}) {
	  $modified_peptide .= 'c['.int($modifications->{$i}).']';
	}
      } else {
	$modified_peptide = $peptide_sequence;
      }


      my $charge = $self->{pepcache}->{charge};

      my $peptide_accession = &main::getPeptideAccession(
        sequence => $peptide_sequence,
      );

      #### Store the information into an array for caching
      # 01/09 tmf: I think the test below is a bug. Just above,
      #  we test for prob > 0.5 & state why we don't use P_threshold.
      # However, if we allow all with prob > 0.5 here, we will get
      # lots of warnings that these peptides are missing from
      # ProteinProphet_data_list. Need to resolve this.
      if ($probability >= $self->{P_threshold}) {
	push(@{ $self->{identification_list} },
          [$self->{search_batch_id},
	   $self->{pepcache}->{spectrum},
	   $peptide_accession,
	   $peptide_sequence,
	   $self->{pepcache}->{peptide_prev_aa},
	   $modified_peptide,
	   $self->{pepcache}->{peptide_next_aa},
	   $charge,
           $probability,
           $self->{pepcache}->{massdiff},
           $self->{pepcache}->{protein_name},
	  ]
	);
      }
    }


    #### Clear out the cache
    delete($self->{pepcache});

    #### Increase the counters and print some progress info
    $self->{counter}++;
    print "$self->{counter}..." if ($self->{counter} % 1000 == 0);

  }


  #### If there's an object on the stack consider popping it off
  if (scalar @{$self->object_stack()}){

    #### If the top object on the stack is the correct one, pop it off
    #### else die bitterly    my $peptide_sequence = $attrs{peptide_sequence} || die("No sequence");

    if ($self->object_stack->[-1]->{name} eq "$localname") {
      pop(@{$self->object_stack});
    } else {
      die("STACK ERROR: Wanted to pop off an element of type '$localname'".
        " but instead we found '".$self->object_stack->[-1]->{name}."'!");
    }

  } else {
    die("STACK ERROR: Wanted to pop off an element of type '$localname'".
        " but instead we found the stack empty!");
  }

}



###############################################################################
# protXML_end_element
###############################################################################
sub protXML_end_element {
  my ($self,$uri,$localname,$qname) = @_;

  #### If this is a pepetide, then update the number of peptides
  if ($localname eq 'peptide') {
    my $peptide_sequence = $self->{pepcache}->{peptide}
      || die("ERROR: No peptide sequence in the cache!");

    my $initial_probability = $self->{pepcache}->{initial_probability};

    #### If this peptide passes the threshold, store it
    #### EWD Add -0.05 so compensate for new ProteinProphet by DS which
    #### artificially degrades initial_probabilities by .001
    ####  tmf: this means we are storing more peptides than we need
    ####  in this hash, but that's OK.
    #### tmf: Add -0.2 instead of -0.05, since init_prob is taken
    ####   from all-experiment iProphet run whereas we output all
    ####   peptides whose final adjusted prob is based on
    ####   per-experiment iProphet runs ... (reasoning not exactly right)

    if ($initial_probability >= $self->{P_threshold}-.2) {

      #### Create the modified peptide string
      my $modified_peptide = '';
      my $pep_key = '';
      my $modifications = $self->{pepcache}->{modifications};
      if ($modifications) {
	my $i = 0;
	if ($modifications->{$i}) {
	  $modified_peptide .= 'n['.int($modifications->{$i}).']';
	}
	for ($i=1; $i<=length($peptide_sequence); $i++) {
	  my $aa = substr($peptide_sequence,$i-1,1);
	  if ($modifications->{$i}) {
	    $aa .= '['.int($modifications->{$i}).']';
	  }
	  $modified_peptide .= $aa;
	}
	if ($modifications->{$i}) {
	  $modified_peptide .= 'c['.int($modifications->{$i}).']';
	}
      } else {
	$modified_peptide = $peptide_sequence;
      }

      #### If there is a charge, prepend charge to peptide string
      #### to create key for storing ProteinProphet info.
      my $charge = $self->{pepcache}->{charge};
      if ($charge) {
        $pep_key = sprintf("%s-%s", $charge, $modified_peptide);
      } else {
        $pep_key = $modified_peptide;
      }

      #### As of 12/18/08, iProphet or ProteinProphet drops mod and
      #### charge info, so at this point charge is undefined,
      #### modified peptide has no mods, and pep_key is a stripped peptide.

      #### Store the information into a hash for access during peptide reading
      $self->{ProteinProphet_data_list}->{$pep_key} = {
        search_batch_id => $self->{search_batch_id},
	charge => $charge,
        initial_probability => $initial_probability,
        nsp_adjusted_probability => $self->{pepcache}->{nsp_adjusted_probability},
        n_sibling_peptides => $self->{pepcache}->{n_sibling_peptides},
        n_adjusted_observations => $self->{pepcache}->{n_instances},
        protein_name => $self->{protein_name},
      };


      #### If there are indistinguishable peptides, modify them, too
      foreach my $indis_peptide ( keys(%{$self->{pepcache}->{indistinguishable_peptides}}) ) {
	my $modified_indis_peptide = '';
	if ($modifications) {
	  my $i = 0;
	  if ($modifications->{$i}) {
	    $modified_indis_peptide .= 'n['.int($modifications->{$i}).']';
	  }
	  for ($i=1; $i<=length($indis_peptide); $i++) {
	    my $aa = substr($indis_peptide,$i-1,1);
	    if ($modifications->{$i}) {
	      $aa .= '['.int($modifications->{$i}).']';
	    }
	    $modified_indis_peptide .= $aa;
	  }
	  if ($modifications->{$i}) {
	    $modified_indis_peptide .= 'c['.int($modifications->{$i}).']';
	  }
	} else {
	  $modified_indis_peptide = $indis_peptide;
	}

        if ($charge) {
          $pep_key = "${charge}-$modified_indis_peptide";
        } else {
          $pep_key = $modified_indis_peptide;
        }

	$self->{ProteinProphet_data_list}->{$pep_key} = {
          search_batch_id => $self->{search_batch_id},
	  charge => $charge,
          initial_probability => $initial_probability,
          nsp_adjusted_probability => $self->{pepcache}->{nsp_adjusted_probability},
          n_sibling_peptides => $self->{pepcache}->{n_sibling_peptides},
          n_adjusted_observations => $self->{pepcache}->{n_instances},
          protein_name => $self->{protein_name},
        };
      }




    }

    #### Clear out the cache
    delete($self->{pepcache});

    #### Increase the counters and print some progress info
    $self->{Protcounter}++;
    print "." if ($self->{Protcounter} % 100 == 0);

  }


  #### If there's an object on the stack consider popping it off
  if (scalar @{$self->object_stack()}){

    #### If the top object on the stack is the correct one, pop it off
    #### else die bitterly
    if ($self->object_stack->[-1]->{name} eq "$localname") {
      pop(@{$self->object_stack});
    } else {
      die("STACK ERROR: Wanted to pop off an element of type '$localname'".
        " but instead we found '".$self->object_stack->[-1]->{name}."'!");
    }

  } else {
    die("STACK ERROR: Wanted to pop off an element of type '$localname'".
        " but instead we found the stack empty!");
  }

}




###############################################################################
###############################################################################
###############################################################################
# continuation of main package
###############################################################################
package main;


#### Do the SBEAMS authentication and exit if a username is not returned
exit unless ($current_username =
    $sbeams->Authenticate(work_group=>'PeptideAtlas_admin'));


#### Print the header, do what the program does, and print footer
$sbeams->printPageHeader();
main();
$sbeams->printPageFooter();



###############################################################################
# saveBestProbPerPep
###############################################################################
sub saveBestProbPerPep{
  my %args = @_;
  my $best_prob_per_pep = $args{'best_prob_per_pep'}
    || die("No best_prob_per_pep hash provided");
  my $identification_list = $args{'identification_list'}
    || die("No peptide identification_list provided");
  #printf "Size of best_prob_per_pep: %d\n",
      #scalar(keys(%{$best_prob_per_pep}));

  foreach my $identification ( @{$identification_list} ) {
    my $prob = $identification->[8];
    if ($prob eq "probability") {
      next;
    }
    my $stripped_pep = $identification->[3];
    # concatenate charge, hyphen, and modified peptide to create unstripped
    my $unstripped_pep = "$identification->[7]-$identification->[5]";
    # stripped peptide
    if (exists($best_prob_per_pep->{$stripped_pep})) {
      if ( $prob > $best_prob_per_pep->{$stripped_pep} ) {
        $best_prob_per_pep->{$stripped_pep} = $prob;
      }
    } else {
      $best_prob_per_pep->{$stripped_pep} = $prob;
    }
    # unstripped peptide
    if ($unstripped_pep ne $stripped_pep) {
      if (exists($best_prob_per_pep->{$unstripped_pep})) {
        if ( $prob > $best_prob_per_pep->{$unstripped_pep} ) {
          $best_prob_per_pep->{$unstripped_pep} = $prob;
        }
      } else {
        $best_prob_per_pep->{$unstripped_pep} = $prob;
      }
    } else {
    }
  }
}

###############################################################################
# showBestProbPerPep (for development/debugging)
###############################################################################
sub showBestProbPerPep{
  my %args = @_;
  my $best_prob_per_pep = $args{'best_prob_per_pep'}
    || die("No best_prob_per_pep hash provided");
  print"\nBest probability per peptide:\n";
  #while ((my $pep, my $best_prob) = each ( %{$best_prob_per_pep} )) {
  foreach my $pep (sort ( keys %{$best_prob_per_pep} )) {
    my $best_prob = $best_prob_per_pep->{$pep};
    print "$pep: $best_prob\n";
  }
}

###############################################################################
# Main part of the script
###############################################################################
sub main {

  #### Print out the header
  unless ($QUIET) {
    $sbeams->printUserContext();
    print "\n";
  }

  #### Process additional input parameters
  my $P_threshold = $OPTIONS{P_threshold};
  $P_threshold = '0.9' unless (defined($P_threshold));

  ## check that --output_file was passed and that the directory of output_file exists
  my $check_dir = $OPTIONS{output_file} || die "need output file path: --output_file";
  $check_dir =~ s/(.+)\/(.*)$/$1/gi;
  if (-d $check_dir)
  {
    print "Checked: The output directory ($check_dir) exists\n";
  } else
  {
    print "ERROR: The output directory ($check_dir) does not exist($!)\n";
    exit;
  }

  #### Hard code testing
  $OPTIONS{master_ProteinProphet_file} = "${check_dir}/../analysis/interact-all-prot.xml";


  #### Set up the Xerces parser
  my $parser = XML::Xerces::XMLReaderFactory::createXMLReader();

  $parser->setFeature("http://xml.org/sax/features/namespaces", $namespace);

  if ($validate eq $XML::Xerces::SAX2XMLReader::Val_Auto) {
    $parser->setFeature("http://xml.org/sax/features/validation", 1);
    $parser->setFeature("http://apache.org/xml/features/validation/dynamic",1);

  } elsif ($validate eq $XML::Xerces::SAX2XMLReader::Val_Never) {
    $parser->setFeature("http://xml.org/sax/features/validation", 0);

  } elsif ($validate eq $XML::Xerces::SAX2XMLReader::Val_Always) {
    $parser->setFeature("http://xml.org/sax/features/validation", 1);
    $parser->setFeature("http://apache.org/xml/features/validation/dynamic",0);
  }

  $parser->setFeature("http://apache.org/xml/features/validation/schema",
    $schema);


  #### Create the error handler and content handler
  my $error_handler = XML::Xerces::PerlErrorHandler->new();
  $parser->setErrorHandler($error_handler);

  my $CONTENT_HANDLER = MyContentHandler->new();
  $parser->setContentHandler($CONTENT_HANDLER);

  $CONTENT_HANDLER->setVerbosity($VERBOSE);
  $CONTENT_HANDLER->{counter} = 0;
  $CONTENT_HANDLER->{P_threshold} = $P_threshold;
  $CONTENT_HANDLER->{OPTIONS} = \%OPTIONS;

  #### Array of documents to process in order
  my @documents;

  #### If a list of search_batch_ids was provided, find the corresponding
  #### documents
  if ($search_batch_ids && 0) {
    my @search_batch_ids = split(/,/,$search_batch_ids);
    foreach my $search_batch_id (@search_batch_ids) {
      my $ProteinProphet_file = guess_source_file(
        search_batch_id => $search_batch_id,
      );
      if ($ProteinProphet_file) {
	#$documents{$ProteinProphet_file}->{search_batch_id} = $search_batch_id;
      } else {
	die("ERROR: Unable to determine document for search_batch_id ".
	    "$search_batch_id");
      }
    }
  }

  #### If a source file containing the list of search_batch_ids was provided,
  #### read it and find the corresponding documents
  if ($source_file) {
    my @search_batch_ids;
    open(SOURCE_FILE,$source_file)
      || die("ERROR: Unable to open $source_file");
    while (my $line = <SOURCE_FILE>) {
      chomp($line);
      next if ($line =~ /^\s*#/);
      next if ($line =~ /^\s*$/);
      my ($search_batch_id,$path) = split(/\s+/,$line);
      my $filepath = $path;

      if ($filepath !~ /\.xml/) {
	my @possible_interact_names = (
          'interact-prob.pep.xml',
          'interact-prob.xml',
          'interact-spec.pep.xml',
          'interact-spec.xml',
          'interact.xml',
          'interact.pep.xml',
          'interact-combined.pep.xml',
        );
	my $found_file = 0;
	foreach my $possible_name ( @possible_interact_names ) {
	  if ( -e $path.'/'.$possible_name ) {
	    $found_file = 1;
	    $filepath = $path.'/'.$possible_name;
	    last;
	  }
	}
	unless ( $found_file ) {
	  print "ERROR: Unable to auto-detect an interact file in $path\n";
	  next;
	}
      }

      unless ( -e $filepath ) {
	print "ERROR: Specified interact file '$filepath' does not exist!\n";
	next;
      }


      my ($pepXML_document);

      $pepXML_document->{filepath} = $filepath;
      $pepXML_document->{search_batch_id} = $search_batch_id;
      $pepXML_document->{document_type} = 'pepXML';
      push(@documents,$pepXML_document);
      print "Will read $pepXML_document->{filepath}\n";

      push(@search_batch_ids,$search_batch_id);
    }
    $search_batch_ids = join(',',@search_batch_ids);
  }


  #### Loop over all input files converting pepXML to identlist format
  #### unless it has already been done
  if ($best_probs_from_protxml) {
    print "Will get best initial probs from protXML file[s].\n";
  } else {
    print "Will get best initial probs from pepXML files.\n";
    $CONTENT_HANDLER->{best_prob_per_pep} = {};
  }
  my @identlist_files;
  my %decoy_corrections;
  my $spectral_peptides;
  my $first_loop = 1;

  #### First pass: read or create cache files,
  ####  saving best probabilities for each stripped and unstripped
  ####  peptide
  print "First pass over pepXML files/caches\n";
  foreach my $document ( @documents ) {
    my $filepath = $document->{filepath};
    $CONTENT_HANDLER->{search_batch_id} = $document->{search_batch_id};
    $CONTENT_HANDLER->{document_type} = $document->{document_type};
    $CONTENT_HANDLER->{identification_list} = [];

    #### Determine the identlist file path and name
    my $identlist_file = $filepath;
    $identlist_file =~ s/\.xml$/.PAidentlist/;
    push(@identlist_files,$identlist_file);

    #### If the identlist template file already exists, read that instead of pepXML
    if ( -e "${identlist_file}-template") {
      readIdentificationListTemplateFile(
        input_file => "${identlist_file}-template",
        identification_list => $CONTENT_HANDLER->{identification_list},
      );

    #### Otherwise read the pepXML
    } else {

      print "INFO: Reading $filepath...\n" unless ($QUIET);
      $CONTENT_HANDLER->{document_type} = $document->{document_type};
      $parser->parse (XML::Xerces::LocalFileInputSource->new($filepath));
      print "\n";

      #### Write out the template cache file
      writeIdentificationListTemplateFile(
        output_file => "${identlist_file}-template",
        identification_list => $CONTENT_HANDLER->{identification_list},
      );
    }

    #### Loop through all search_hits, saving the best probability
    #### seen for each peptide in a hash.
    if (!$best_probs_from_protxml) {
      saveBestProbPerPep(
          best_prob_per_pep => $CONTENT_HANDLER->{best_prob_per_pep},
          identification_list => $CONTENT_HANDLER->{identification_list},
        );
    }
  }

  #### Development/debugging: print the best prob for each pep
  if (!$best_probs_from_protxml && 0) {
    showBestProbPerPep(
        best_prob_per_pep => $CONTENT_HANDLER->{best_prob_per_pep},
      );
  }


  #### Second pass: read ProteinProphet file(s), read each cache file again,
  ####  then write out all the peptides and probabilities including
  ####  ProteinProphet information
  print "Second pass over caches\n";

  foreach my $document ( @documents ) {
    my $filepath = $document->{filepath};
    $CONTENT_HANDLER->{search_batch_id} = $document->{search_batch_id};
    $CONTENT_HANDLER->{document_type} = $document->{document_type};
    $CONTENT_HANDLER->{identification_list} = [];

    #### Reset the ProteinProphet data structure unless using a master
    #### (except if the first loop, then do reset)
    unless ($OPTIONS{master_ProteinProphet_file} && $first_loop == 0) {
      $CONTENT_HANDLER->{ProteinProphet_data_list} = {};
    }

    #### First get the ProteinProphet information
    my $proteinProphet_filepath;

    #### If a single master ProteinProphet file was specified, prepare that
    if ($OPTIONS{master_ProteinProphet_file}) {
      if ($first_loop) {
	$proteinProphet_filepath = $OPTIONS{master_ProteinProphet_file};
	unless (-e $proteinProphet_filepath) {
	  die("ERROR: Specified master ProteinProphet file not found '$proteinProphet_filepath'\n");
	}
        print "INFO: Reading $proteinProphet_filepath...\n" unless ($QUIET);
        $CONTENT_HANDLER->{document_type} = 'protXML';
        $parser->parse (XML::Xerces::LocalFileInputSource->new($proteinProphet_filepath));
        print "\n";

	#### If it exists, read the SpectraST library
	$spectral_peptides = readSpectralLibraryPeptides(
          input_file => "analysis/consensus.sptxt",
        );

      }

    #### Else we'll read one ProteinProphet file per pepXML file
    } else {
      $proteinProphet_filepath = $filepath;
      $proteinProphet_filepath =~ s/\.xml/-prot.xml/;

      unless (-e $proteinProphet_filepath) {
	#### Hard coded funny business for Novartis
	if ($proteinProphet_filepath =~ /Novartis/) {
	  if ($proteinProphet_filepath =~ /interact-prob_\d/) {
	    $proteinProphet_filepath =~ s/prob_\d/prob_all/;
	  } else {
	    $proteinProphet_filepath = undef;
	  }
	} else {
	  print "ERROR: No ProteinProphet file found for\n  $proteinProphet_filepath\n";
	  $proteinProphet_filepath = undef;
	}
      }

      if ($proteinProphet_filepath) {
        print "INFO: Reading $proteinProphet_filepath...\n" unless ($QUIET);
        $CONTENT_HANDLER->{document_type} = 'protXML';
        $parser->parse (XML::Xerces::LocalFileInputSource->new($proteinProphet_filepath));
        print "\n";
      }
    }


    #### Check to see if there's a decoy correction coefficient
    #### This is very fudgy. This code should be off in SVN and only
    #### enabled for testing
    my $decoy_file = $filepath;
    $decoy_file =~ s/\.xml$/.decoy.txt/;
    if ( -e $decoy_file && 0) {  #### && 0 means this is disabled!!
      open(DECOYFILE,$decoy_file);
      while (my $line = <DECOYFILE>) {
	chomp($line);
	my @columns = split("\t",$line);
	if ($columns[0] == 3) {
	  my $decoy_correction = ( $columns[1] + $columns[2] ) / 2.0;
	  print "INFO: Decoy correction = $decoy_correction\n";
	  $decoy_corrections{$document->{search_batch_id}} = $decoy_correction;
	}
      }
      close(DECOY_FILE);
    } else {
      #print "WARNING: No decoy correction\n";
    }

    #### Determine the identlist file path and name
    my $identlist_file = $filepath;
    $identlist_file =~ s/\.xml$/.PAidentlist/;

    #### Read the identlist template file
    if ( -e "${identlist_file}-template") {
      readIdentificationListTemplateFile(
        input_file => "${identlist_file}-template",
        identification_list => $CONTENT_HANDLER->{identification_list},
        );
    } else {
      die("ERROR: ${identlist_file}-template not found\n");
    }
 
    writeIdentificationListFile(
      output_file => $identlist_file,
      identification_list => $CONTENT_HANDLER->{identification_list},
      ProteinProphet_data => $CONTENT_HANDLER->{ProteinProphet_data_list},
      spectral_library_data => $spectral_peptides,
      P_threshold => $P_threshold,
      best_prob_per_pep => $CONTENT_HANDLER->{best_prob_per_pep},
    );

    $first_loop = 0;
  }


  #### Create a combined identlist file
  my $combined_identlist_file = "DATA_FILES/PeptideAtlasInput_concat.PAidentlist";
  open(OUTFILE,">$combined_identlist_file") ||
    die("ERROR: Unable to open for write '$combined_identlist_file'");
  close(OUTFILE);


  #### Get the columns headings
  open(INFILE,$identlist_files[0]) ||
    die("ERROR: Unable to open for read '$identlist_files[0]'");
  my $header = <INFILE> ||
    die("ERROR: Unable to read header from '$identlist_files[0]'");
  close(INFILE);
  chomp($header);
  my @column_names = split("\t",$header);


  #### Loop over all cache files and add to combined identlist file
  foreach my $identlist_file ( @identlist_files ) {
    print "INFO: Adding to master list: '$identlist_file'\n";
    system("grep -v '^search_batch_id' $identlist_file >> $combined_identlist_file");
  }


  #### If we have decoy corrections, apply them and write out a new file
  if (%decoy_corrections) {
    my $output_file = $combined_identlist_file;
    $output_file =~ s/concat/concor/;
    apply_decoy_corrections(
      input_file => $combined_identlist_file,
      output_file => $output_file,
      decoy_corrections => \%decoy_corrections,
    );
  }


  #### Sort the combined file by peptide
  my $sorted_identlist_file = "DATA_FILES/PeptideAtlasInput_sorted.PAidentlist";
  print "INFO: Sorting master list '$combined_identlist_file'\n";
  system("sort -k 3,3 -k 2,2 $combined_identlist_file >> $sorted_identlist_file");


  #### Open APD format TSV file for writing
  my $output_tsv_file = $OPTIONS{output_file} || 'PeptideAtlasInput.tsv';
  openAPDFormatFile(
    output_file => $output_tsv_file,
  );


  #### Open PeptideAtlas XML format file for writing
  my $output_PAxml_file = $output_tsv_file;
  $output_PAxml_file =~ s/\.tsv$//i;
  $output_PAxml_file .= '.PAxml';
  openPAxmlFile(
    output_file => $output_PAxml_file,
    P_threshold => $CONTENT_HANDLER->{P_threshold},
  );


  #### If we have decoy corrections, apply them and write out a new file
  if (%decoy_corrections) {
    my $output_file = $sorted_identlist_file;
    $output_file =~ s/sorted/srtcor/;
    apply_decoy_corrections(
      input_file => $sorted_identlist_file,
      output_file => $output_file,
      decoy_corrections => \%decoy_corrections,
    );
    $sorted_identlist_file = $output_file;
  }


  #### Open the combined, sorted identlist file
  open(INFILE,$sorted_identlist_file) ||
    die("ERROR: Unable to open for write '$sorted_identlist_file'");


  #### Loop through all rows, grouping by peptide sequence, writing
  #### out information for each group of peptide sequence
  my $prev_peptide_sequence = '';
  my $done = 0;
  my @rows;
  while (! $done) {
    my $line = <INFILE>;
    my @columns;
    my $peptide_sequence = 'xxx';

    #### Unless we're at the end of the file
    if ($line) {
      chomp($line);
      @columns = split("\t",$line);
      $peptide_sequence = $columns[3];
    }

    #### If we're encountering the new peptide, process and write the previous
    if ($prev_peptide_sequence && $peptide_sequence ne $prev_peptide_sequence) {
      my $peptide_summary = coalesceIdentifications(
        rows => \@rows,
        column_names => \@column_names,
      );
      writeToAPDFormatFile(
        peptide_summary => $peptide_summary,
      );
      writeToPAxmlFile(
        peptide_summary => $peptide_summary,
      );
      $prev_peptide_sequence = $peptide_sequence;
      @rows = ();
    }

    #### If there is no peptide sequence, the we're at the end of the file
    if ($peptide_sequence eq 'xxx') {
      last;
    }

    push(@rows,\@columns);

    #### Needed for the very first row
    unless ($prev_peptide_sequence) {
      $prev_peptide_sequence = $peptide_sequence;
    }

  }


  #### Close files
  closeAPDFormatFile();
  closePAxmlFile();


  #### Write out information about the objects we've loaded if verbose
  if ($VERBOSE) {
    showContentHandlerContents(
      content_handler => $CONTENT_HANDLER,
    );
  }

  print "\n\n" unless ($QUIET);

} # end main



###############################################################################
###############################################################################
###############################################################################
###############################################################################


###############################################################################
# guess_source_file
###############################################################################
sub guess_source_file {
  my %args = @_;
  my $search_batch_id = $args{'search_batch_id'};

  my ($sql,@biosequence_set_ids);

  #### If a search_batch_id was provided
  unless (defined($search_batch_id) && $search_batch_id > 0) {
    return;
  }


  #### Query to find the biosequence_set_id for this tag
  $sql = qq~
    SELECT data_location
      FROM $TBPR_SEARCH_BATCH
     WHERE search_batch_id = '$search_batch_id'
  ~;
  print "$sql\n" if ($VERBOSE);

  my ($data_location) = $sbeams->selectOneColumn($sql);

  #$data_location = "/sbeams/archive/$data_location";

  if ($data_location) {
      if (-e "$data_location/interact-prob-prot.xml") {
          return "$data_location/interact-prob-prot.xml";

      } elsif (-e "$data_location/interact-prot.xml") {
          return "$data_location/interact-prot.xml";

      } else {
	die("ERROR: Unable to find a ProteinProphet file for $data_location");
      }
  }

  return;

} # end guess_source_file



###############################################################################
# getPeptideAccession
###############################################################################
sub getPeptideAccession {
  my %args = @_;
  my $sequence = $args{'sequence'};


  #### If we haven't loaded the peptide accessions hash yet, do it now
  unless (%peptide_accessions) {
    #my $sql = qq~
    #   SELECT peptide_sequence,peptide_accession
    #     FROM $TBAT_PEPTIDE P
    #~;
    my $sql = qq~
       SELECT peptide,peptide_identifier_str
         FROM $TBAPD_PEPTIDE_IDENTIFIER
    ~;
    print "Fetching all peptide accessions...\n";
    %peptide_accessions = $sbeams->selectTwoColumnHash($sql);
    print "  Loaded ".scalar(keys(%peptide_accessions))." peptides.\n";
    #### Just in case the table is empty, put in a bogus hash entry
    #### to prevent triggering a reload attempt
    $peptide_accessions{' '} = ' ';
  }


  #my $peptide_accession = $peptide_accessions{$sequence};
  #if ($peptide_accession !~ /PAp/) {
  #  die("ERROR: peptide_accession is $peptide_accession");
  #}

  return $peptide_accessions{$sequence} if ($peptide_accessions{$sequence});


  #### FIXME: The following is code stolen from
  #### $SBEAMS/lib/script/Proteomics/update_peptide_summary.pl
  #### This should be unified into one piece of code eventually

  my $peptide = $sequence;

  #### See if we already have an identifier for this peptide
  my $sql = qq~
    SELECT peptide_identifier_str
      FROM $TBAPD_PEPTIDE_IDENTIFIER
     WHERE peptide = '$peptide'
  ~;
  my @peptides = $sbeams->selectOneColumn($sql);

  #### If more than one comes back, this violates UNIQUEness!!
  if (scalar(@peptides) > 1) {
    die("ERROR: More than one peptide returned for $sql");
  }

  #### If we get exactly one back, then return it
  if (scalar(@peptides) == 1) {
    #### Put this new one in the hash for the next lookup
    $peptide_accessions{$sequence} = $peptides[0];
    return $peptides[0];
  }


  #### Else, we need to add it
  #### Create a hash for the peptide row
  my %rowdata;
  $rowdata{peptide} = $peptide;
  $rowdata{peptide_identifier_str} = 'tmp';

  #### Do the next two statements as a transaction
  $sbeams->initiate_transaction();

  #### Insert the data into the database
  my $peptide_identifier_id = $sbeams->insert_update_row(
    insert=>1,
    table_name=>$TBAPD_PEPTIDE_IDENTIFIER,
    rowdata_ref=>\%rowdata,
    PK=>"peptide_identifier_id",
    PK_value => 0,
    return_PK => 1,
    verbose=>$VERBOSE,
    testonly=>$TESTONLY,
  );

  unless ($peptide_identifier_id > 0) {
    die("Unable to insert modified_peptide for $peptide");
  }


  #### Now that the database furnished the PK value, create
  #### a string according to our rules and UPDATE the record
  my $template = "PAp00000000";
  my $identifier = substr($template,0,length($template) -
    length($peptide_identifier_id)).$peptide_identifier_id;
  $rowdata{peptide_identifier_str} = $identifier;


  #### UPDATE the record
  my $result = $sbeams->insert_update_row(
    update=>1,
    table_name=>$TBAPD_PEPTIDE_IDENTIFIER,
    rowdata_ref=>\%rowdata,
    PK=>"peptide_identifier_id",
    PK_value =>$peptide_identifier_id ,
    return_PK => 1,
    verbose=>$VERBOSE,
    testonly=>$TESTONLY,
  );

  #### Commit the INSERT+UPDATE pair
  $sbeams->commit_transaction();

  #### Put this new one in the hash for the next lookup
  $peptide_accessions{$sequence} = $identifier;

  return($identifier);

} # end getPeptideAccession


###############################################################################
# getBiosequenceAttributes
###############################################################################
sub getBiosequenceAttributes {
  my %args = @_;
  my $biosequence_name = $args{'biosequence_name'};


  #### If we haven't loaded the biosequence attributes hash yet, do it now
  unless (%biosequence_attributes) {
    my $sql = qq~
       SELECT biosequence_id,biosequence_name,biosequence_gene_name,
              biosequence_accession,biosequence_desc
         FROM $TBAT_BIOSEQUENCE
        WHERE biosequence_set_id = $bssid
    ~;


    print "Fetching all biosequence accessions...\n";
    print "$sql";
    my @rows = $sbeams->selectSeveralColumns($sql);
    foreach my $row (@rows) {
      $biosequence_attributes{$row->[1]} = $row;
    }
    print "  Loaded ".scalar(@rows)." biosequences.\n";
    #### Just in case the table is empty, put in a bogus hash entry
    #### to prevent triggering a reload attempt
    $biosequence_attributes{' '} = ' ';
  }


  return $biosequence_attributes{$biosequence_name};

} # end getBiosequenceAttributes



###############################################################################
# openAPDFormatFile
###############################################################################
sub openAPDFormatFile {
  my %args = @_;
  my $output_file = $args{'output_file'} || die("No output file provided");

  print "Opening output file '$output_file'...\n";

  our $TSVOUTFILE;
  open(TSVOUTFILE,">$output_file")
    || die("ERROR: Unable to open '$output_file' for write");
  $TSVOUTFILE = *TSVOUTFILE;

  print TSVOUTFILE "peptide_identifier_str\tbiosequence_gene_name\tbiosequence_accession\treference\tpeptide\tn_peptides\tmaximum_probability\tn_experiments\tobserved_experiment_list\tbiosequence_desc\tsearched_experiment_list\n";

  return 1;

} # end openAPDFormatFile



###############################################################################
# writeToAPDFormatFile
###############################################################################
sub writeToAPDFormatFile {
  my %args = @_;
  my $peptide_summary = $args{'peptide_summary'}
    || die("No peptide_summary provided");

  our $TSVOUTFILE;

  while (my ($peptide_sequence,$attributes) =
            each %{$peptide_summary}) {

    my $n_experiments = scalar(keys(%{$attributes->{search_batch_ids}}));

    my $peptide_accession = getPeptideAccession(
      sequence => $peptide_sequence,
    );
    my $protein_name = $attributes->{protein_name};

    my $biosequence_attributes;
    my ($gene_name,$description) = ('','');
    if ($biosequence_attributes = getBiosequenceAttributes(
      biosequence_name => $protein_name,
							  )
       ) {
      $gene_name = $biosequence_attributes->[2];
      $description = $biosequence_attributes->[4];
    }

    print $TSVOUTFILE "$peptide_accession\t$gene_name\t$protein_name\t$protein_name\t$peptide_sequence\t".
      $attributes->{n_instances}."\t  ".
      $attributes->{best_probability}."\t$n_experiments\t".
      join(",",keys(%{$attributes->{search_batch_ids}}))."\t".
      "\"$description\"\t\"$search_batch_ids\"\n";

  }

  return(1);

} # end writeToAPDFormatFile



###############################################################################
# closeAPDFormatFile
###############################################################################
sub closeAPDFormatFile {
  my %args = @_;

  our $TSVOUTFILE;

  close($TSVOUTFILE);

  return(1);

} # end closeAPDFormatFile



###############################################################################
# writeAPDFormatFile - deprecated
###############################################################################
sub writeAPDFormatFile {
  my %args = @_;
  my $output_file = $args{'output_file'} || die("No output file provided");
  my $peptides = $args{'peptide_hash'} || die("No output peptide_hash provided");

  print "Writing output file '$output_file'...\n";

  open(OUTFILE,">$output_file")
    || die("ERROR: Unable to open '$output_file' for write");

  print OUTFILE "peptide_identifier_str\tbiosequence_gene_name\tbiosequence_accession\treference\tpeptide\tn_peptides\tmaximum_probability\tn_experiments\tobserved_experiment_list\tbiosequence_desc\tsearched_experiment_list\n";

  while (my ($peptide_sequence,$attributes) =
            each %{$peptides}) {

    my $n_experiments = scalar(keys(%{$attributes->{search_batch_ids}}));

    my $peptide_accession = getPeptideAccession(
      sequence => $peptide_sequence,
    );
    my $protein_name = $attributes->{protein_name};

    my $biosequence_attributes;
    my ($gene_name,$description) = ('','');
    if ($biosequence_attributes = getBiosequenceAttributes(
      biosequence_name => $protein_name,
							  )
       ) {
      $gene_name = $biosequence_attributes->[2];
      $description = $biosequence_attributes->[4];
    }

    print OUTFILE "$peptide_accession\t$gene_name\t$protein_name\t$protein_name\t$peptide_sequence\t".
      $attributes->{n_instances}."\t  ".
      $attributes->{best_probability}."\t$n_experiments\t".
      join(",",keys(%{$attributes->{search_batch_ids}}))."\t".
      "\"$description\"\t\"$search_batch_ids\"\n";

  }

  close(OUTFILE);

  return(1);

} # end writeAPDFormatFile



###############################################################################
# showContentHandlerContents
###############################################################################
sub showContentHandlerContents {
  my %args = @_;
  my $CONTENT_HANDLER = $args{'content_handler'}
    || die("No CONTENT_HANDLER provided");

  print "\n-------------------------------------------------\n";
  my ($key,$value);
  my ($key2,$value2);

  print "CONTENT_HANDLER:\n";
  while (($key,$value) = each %{$CONTENT_HANDLER}) {
    print "CONTENT_HANDLER->{$key} = $value:\n";
  }

  print "\n";
  while (($key,$value) = each %{$CONTENT_HANDLER}) {
    print "CONTENT_HANDLER->{$key}\n";

    if ($key eq "UNHANDLED") {
      while (($key2,$value2) = each %{$CONTENT_HANDLER->{$key}}) {
        print "  $key2 = $value2\n";
      }

    } elsif ($key eq "OBJ_STACK") {
      foreach $key2 (@{$CONTENT_HANDLER->{$key}}) {
        print "  $key2\n";
      }

    } elsif ($key eq "peptides" || $key eq "all_spectra") {
      my $tmpcnt = 0;
      while (($key2,$value2) = each %{$CONTENT_HANDLER->{$key}}) {
        print "  $key2 = $value2\n";
        $tmpcnt++;
        if ($tmpcnt > 20) {
          print "  etc...\n";
          last;
        }
      }

    } else {
      if (ref($CONTENT_HANDLER->{$key})) {
        foreach $key2 (@{$CONTENT_HANDLER->{$key}}) {
          print "  $key2\n";
        }
      }
    }

  } # end while


  #print Dumper($CONTENT_HANDLER->{peptides});


} # end showContentHandlerContents



###############################################################################
# apply_decoy_corrections
###############################################################################
sub apply_decoy_corrections {
  my %args = @_;
  my $input_file = $args{'input_file'} || die("No input_file provided");
  my $output_file = $args{'output_file'} || die("No output_file provided");
  my $decoy_corrections = $args{'decoy_corrections'} || die("No decoy_corrections provided");

  #### Open the combined, sorted identlist file
  open(INFILE,$input_file) ||
    die("ERROR: Unable to open for read '$input_file'");
  open(OUTFILE,">$output_file") ||
    die("ERROR: Unable to open for write '$output_file'");

  while (my $line = <INFILE>) {
    my @columns;
    chomp($line);
    @columns = split("\t",$line);
    my $search_batch_id = $columns[0];
    my $probability = $columns[8];
    my $decoy_correction = $decoy_corrections->{$search_batch_id};
    if ($decoy_correction) {
      $probability = 1-((1-$probability)/$decoy_correction);
      $columns[8] = sprintf("%.4f",$probability);
    } else {
      print "WARNING: No decoy correction available for searcb_batch_id '$search_batch_id'\n";
    }
    print OUTFILE join("\t",@columns)."\n";
  }

  close(INFILE);
  close(OUTFILE);

} # end apply_decoy_corrections



###############################################################################
# coalesceIdentifications
###############################################################################
sub coalesceIdentifications {
  my %args = @_;
  my $rows = $args{'rows'} || die("No rows provided");
  my $column_names = $args{'column_names'} || die("No column_names provided");
  my $decoy_corrections = $args{'decoy_corrections'};
  use Data::Dumper;

  my $summary;

  #### Make a hash of the column names
  my $columns;
  for (my $index=0; $index<scalar(@{$column_names}); $index++) {
    $columns->{$column_names->[$index]} = $index;
  }
  #print Dumper( [$columns] );

  #### Loop over each row, organizing the information
  foreach my $row ( @{$rows} ) {
    my $peptide_sequence = $row->[$columns->{peptide_sequence}];
    $summary->{$peptide_sequence}->{peptide_sequence} = $peptide_sequence;
    my $info = $summary->{$peptide_sequence};
    $info->{peptide_accession} = $row->[$columns->{peptide_accession}];
    $info->{peptide_sequence} = $peptide_sequence;
    $info->{preceding_residue} = $row->[$columns->{preceding_residue}];
    $info->{following_residue} = $row->[$columns->{following_residue}];
    if (!defined($info->{best_probability}) ||
	$info->{best_probability} < $row->[$columns->{probability}]) {
      $info->{best_probability} = $row->[$columns->{probability}];
    }
    $info->{n_instances}++;
    $info->{protein_name} = $row->[$columns->{protein_name}];

    #### Record that this peptide was seen in this search_batch
    my $search_batch_id = $row->[$columns->{search_batch_id}];
    $info->{search_batch_ids}->{$search_batch_id}++;

    #### Incorporate the ProteinProphet information
    # later below in modification area


    #### Now store information for this modification of the peptide
    my $modified_sequence = $row->[$columns->{modified_peptide_sequence}];
    my $charge = $row->[$columns->{charge}];
    $info->{modifications}->{$modified_sequence}->{$charge}->{n_instances}++;
    my $modinfo = $info->{modifications}->{$modified_sequence}->{$charge};
    if (!defined($modinfo->{best_probability}) ||
	$modinfo->{best_probability} < $row->[$columns->{probability}]) {
      $modinfo->{best_probability} = $row->[$columns->{probability}];
    }

    if (exists($modinfo->{search_batch_ids}->{$search_batch_id})) {
      #### Already counted information for this search batch
    } else {
      if (exists($modinfo->{best_adjusted_probability})) {
	if ($row->[$columns->{adjusted_probability}] > $modinfo->{best_adjusted_probability}) {
	  $modinfo->{best_adjusted_probability} = $row->[$columns->{adjusted_probability}];
	}
      }
      $modinfo->{n_adjusted_observations} += $row->[$columns->{n_adjusted_observations}];
      $modinfo->{n_sibling_peptides} += $row->[$columns->{n_sibling_peptides}];

      #### Since this is a new mod instance, update the overall peptide info, too
      if (exists($info->{best_adjusted_probability})) {
	if ($row->[$columns->{adjusted_probability}] > $info->{best_adjusted_probability}) {
	  $info->{best_adjusted_probability} = $row->[$columns->{adjusted_probability}];
	}
      }
      $info->{n_adjusted_observations} += $row->[$columns->{n_adjusted_observations}];
      #### FIXME This below is not the best way to calculate n_sibling_peptides.
      #### because if a peptides is seen in two different charge states, the
      #### n_sibling_peptides will be approximately twice what is fair.
      #### n_sibling_peptides will often be inflated, but it's not clear how to do this best
      $info->{n_sibling_peptides} += $row->[$columns->{n_sibling_peptides}];
    }

    $modinfo->{search_batch_ids}->{$search_batch_id}++;

  }

  #print Dumper( [$summary] );
  #exit;

  return $summary;
}


###############################################################################
# openPAxmlFile
###############################################################################
sub openPAxmlFile {
  my %args = @_;
  my $output_file = $args{'output_file'} || die("No output file provided");
  my $P_threshold = $args{'P_threshold'}
    || die("No output P_threshold provided");


  print "Opening output file '$output_file'...\n";


  #### Open and write header
  our $PAXMLOUTFILE;
  open(PAXMLOUTFILE,">$output_file")
    || die("ERROR: Unable to open '$output_file' for write");
  print PAXMLOUTFILE qq~<?xml version="1.0" encoding="UTF-8"?>\n~;
  $PAXMLOUTFILE = *PAXMLOUTFILE;

  #### Write out parent build element
  print PAXMLOUTFILE encodeXMLEntity(
    entity_name => 'atlas_build',
    indent => 0,
    entity_type => 'open',
    attributes => {
      probability_threshold => $P_threshold,
    },
  );

  return 1;
}


###############################################################################
# writeToPAxmlFile
###############################################################################
sub writeToPAxmlFile {
  my %args = @_;
  my $peptide_summary = $args{'peptide_summary'}
    || die("No peptide_summary provided");

  our $PAXMLOUTFILE;


  #### Loop over all peptides and write out as XML
  while (my ($peptide_sequence,$attributes) = each %{$peptide_summary}) {

    my $buffer = encodeXMLEntity(
      entity_name => 'peptide_instance',
      indent => 4,
      entity_type => 'open',
      attributes => {
        original_protein_name => $attributes->{protein_name},
        peptide_accession => $attributes->{peptide_accession},
        peptide_sequence => $peptide_sequence,
        peptide_prev_aa => $attributes->{preceding_residue},
        peptide_next_aa => $attributes->{following_residue},
        best_probability => $attributes->{best_probability},
        n_observations => $attributes->{n_instances},
        search_batch_ids => join(",",keys(%{$attributes->{search_batch_ids}})),
        best_adjusted_probability => $attributes->{best_adjusted_probability},
        n_adjusted_observations => $attributes->{n_adjusted_observations},
        n_sibling_peptides => $attributes->{n_sibling_peptides},
      },
    );
    print $PAXMLOUTFILE $buffer;


    #### Diagnostic dump
    #if ($peptide_sequence eq 'SENLVSCVDKNLR') {
    #  use Data::Dumper;
    #  print "\n-----\n".Dumper([$ProPro_peptides->{$peptide_sequence}])."\n-----\n";
    #}


    #### Loop over all the observed modifications and write out
    while (my ($mod_peptide_sequence,$mod_attributes) =
      each %{$attributes->{modifications}}) {

      while (my ($mod_charge,$charge_attributes) = each %{$mod_attributes}) {

        my $buffer = encodeXMLEntity(
          entity_name => 'modified_peptide_instance',
          indent => 8,
          entity_type => 'openclose',
          attributes => {
            peptide_string => $mod_peptide_sequence,
            charge_state => $mod_charge,
            best_probability => $charge_attributes->{best_probability},
            n_observations => $charge_attributes->{n_instances},
            search_batch_ids =>
              join(",",keys(%{$charge_attributes->{search_batch_ids}})),
            best_adjusted_probability => $charge_attributes->{best_adjusted_probability},
            n_adjusted_observations => $charge_attributes->{n_adjusted_observations},
            n_sibling_peptides => $charge_attributes->{n_sibling_peptides},
          },
        );
        print $PAXMLOUTFILE $buffer;

      }

    }


    #### Close peptide_instance tag
    my $buffer = encodeXMLEntity(
      entity_name => 'peptide_instance',
      indent => 4,
      entity_type => 'close',
    );
    print $PAXMLOUTFILE $buffer;

  }


  return(1);

} # end writeToPAxmlFile



###############################################################################
# closePAxmlFile
###############################################################################
sub closePAxmlFile {
  my %args = @_;

  #### Open and write header
  our $PAXMLOUTFILE;

  #### Close parent build element
  my $buffer = encodeXMLEntity(
    entity_name => 'atlas_build',
    indent => 0,
    entity_type => 'close',
  );
  print $PAXMLOUTFILE $buffer;


  close($PAXMLOUTFILE);

  return(1);

} # end closePAxmlFile



###############################################################################
# writePAxmlFile - deprecated
###############################################################################
sub writePAxmlFile {
  my %args = @_;
  my $output_file = $args{'output_file'} || die("No output file provided");
  my $peptides = $args{'peptide_hash'}
    || die("No output peptide_hash provided");
  my $ProPro_peptides = $args{'ProPro_peptide_hash'}
    || die("No output ProPro_peptide_hash provided");
  my $P_threshold = $args{'P_threshold'}
    || die("No output P_threshold provided");


  print "Writing output file '$output_file'...\n";


  #### Open and write header
  open(OUTFILE,">$output_file")
    || die("ERROR: Unable to open '$output_file' for write");
  print OUTFILE qq~<?xml version="1.0" encoding="UTF-8"?>\n~;


  #### Write out parent build element
  print OUTFILE encodeXMLEntity(
    entity_name => 'atlas_build',
    indent => 0,
    entity_type => 'open',
    attributes => {
      probability_threshold => $P_threshold,
    },
  );


  #### Loop over all peptides and write out as XML
  while (my ($peptide_sequence,$attributes) = each %{$peptides}) {

    my $ProteinProphet_info = $ProPro_peptides->{$peptide_sequence};
    my $best_initial_probability = $ProteinProphet_info->{best_initial_probability};
    my $best_adjusted_probability = $ProteinProphet_info->{best_adjusted_probability};
    my $n_adjusted_observations = $ProteinProphet_info->{n_instances};
    my $n_sibling_peptides = $ProteinProphet_info->{n_sibling_peptides};

    print OUTFILE encodeXMLEntity(
      entity_name => 'peptide_instance',
      indent => 4,
      entity_type => 'open',
      attributes => {
        original_protein_name => $attributes->{protein_name},
        peptide_accession => $attributes->{peptide_accession},
        peptide_sequence => $peptide_sequence,
        peptide_prev_aa => $attributes->{peptide_prev_aa},
        peptide_next_aa => $attributes->{peptide_next_aa},
        best_probability => $attributes->{best_probability},
        n_observations => $attributes->{n_instances},
        search_batch_ids => join(",",keys(%{$attributes->{search_batch_ids}})),
        best_adjusted_probability => $best_adjusted_probability,
        #best_initial_probability => $best_initial_probability,
        n_adjusted_observations => $n_adjusted_observations,
        n_sibling_peptides => $n_sibling_peptides,
      },
    );


    #### Diagnostic dump
    #if ($peptide_sequence eq 'SENLVSCVDKNLR') {
    #  use Data::Dumper;
    #  print "\n-----\n".Dumper([$ProPro_peptides->{$peptide_sequence}])."\n-----\n";
    #}


    #### Loop over all the observed modifications and write out
    while (my ($mod_peptide_sequence,$mod_attributes) =
      each %{$attributes->{modifications}}) {

      while (my ($mod_charge,$charge_attributes) = each %{$mod_attributes}) {

	my $ProteinProphet_info = $ProPro_peptides->{$peptide_sequence}->
          {modifications}->{$mod_peptide_sequence}->{$mod_charge};
	my $best_initial_probability = $ProteinProphet_info->{best_initial_probability};
	my $best_adjusted_probability = $ProteinProphet_info->{best_adjusted_probability};
	my $n_adjusted_observations = $ProteinProphet_info->{n_instances};
        my $n_sibling_peptides = $ProteinProphet_info->{n_sibling_peptides};

        print OUTFILE encodeXMLEntity(
          entity_name => 'modified_peptide_instance',
          indent => 8,
          entity_type => 'openclose',
          attributes => {
            peptide_string => $mod_peptide_sequence,
            charge_state => $mod_charge,
            best_probability => $charge_attributes->{best_probability},
            n_observations => $charge_attributes->{n_instances},
            search_batch_ids =>
              join(",",keys(%{$charge_attributes->{search_batch_ids}})),
            best_adjusted_probability => $best_adjusted_probability,
            #best_initial_probability => $best_initial_probability,
            n_adjusted_observations => $n_adjusted_observations,
            n_sibling_peptides => $n_sibling_peptides,
          },
        );

      }

    }


    #### Close peptide_instance tag
    print OUTFILE encodeXMLEntity(
      entity_name => 'peptide_instance',
      indent => 4,
      entity_type => 'close',
    );

  }


  #### Close parent build element
  print OUTFILE encodeXMLEntity(
    entity_name => 'atlas_build',
    indent => 0,
    entity_type => 'close',
  );


  close(OUTFILE);

  return(1);

} # end writePAxmlFile



###############################################################################
# encodeXMLEntity
###############################################################################
sub encodeXMLEntity {
  my %args = @_;
  my $entity_name = $args{'entity_name'} || die("No entity_name provided");
  my $indent = $args{'indent'} || 0;
  my $entity_type = $args{'entity_type'} || 'openclose';
  my $attributes = $args{'attributes'} || '';

  #### Define a string from which to get padding
  my $padstring = '                                                       ';
  my $compact = 0;

  #### Define a stack to make user we are nesting correctly
  our @xml_entity_stack;

  #### Close tag
  if ($entity_type eq 'close') {

    #### Verify that the correct item was on top of the stack
    my $top_entity = pop(@xml_entity_stack);
    if ($top_entity ne $entity_name) {
      die("ERROR forming XML: Was told to close <$entity_name>, but ".
	  "<$top_entity> was on top of the stack!");
    }
    return substr($padstring,0,$indent)."</$entity_name>\n";
  }

  #### Else this is an open tag
  my $buffer = substr($padstring,0,$indent)."<$entity_name";


  #### encode the attribute values if any
  if ($attributes) {

    while (my ($name,$value) = each %{$attributes}) {
      if ($value  && $value ne "")
      {
        if ($compact) {
  	$buffer .= qq~ $name="$value"~;
        } else {
  	$buffer .= "\n".substr($padstring,0,$indent+8).qq~$name="$value"~;
        }
      }
    }

  }

  #### If an open and close tag, write the trailing /
  if ($entity_type eq 'openclose') {
    $buffer .= "/";

  #### Otherwise push the entity on our stack
  } else {
    push(@xml_entity_stack,$entity_name);
  }


  $buffer .= ">\n";

  return($buffer);

} # end encodeXMLEntity



###############################################################################
# writePeptideListFile - deprecated
###############################################################################
sub writePeptideListFile {
  my %args = @_;
  my $output_file = $args{'output_file'} || die("No output file provided");
  my $peptide_list = $args{'peptide_list'}
    || die("No output peptide_list provided");


  print "Writing output file '$output_file'...\n";


  #### Open and write header
  open(OUTFILE,">$output_file")
    || die("ERROR: Unable to open '$output_file' for write");

  my @score_columns = qw ( xcorr deltacn deltacnstar spscore sprank
			   fval ntt nmc massd icat );

  print OUTFILE "search_batch_id\tsequence\tmodified_sequence\tcharge\tprobability\t".
    "protein_name\tspectrum_query\t".join("\t",@score_columns)."\n";

  print "  - writing ".scalar(@{$peptide_list})." peptides\n";
  foreach my $peptide ( @{$peptide_list} ) {
    print OUTFILE "$peptide->[0]\t$peptide->[1]\t$peptide->[2]\t".
      "$peptide->[3]\t$peptide->[4]\t$peptide->[5]\t$peptide->[6]";
    foreach my $column (@score_columns) {
      print OUTFILE "\t".$peptide->[7]->{$column};
    }
    print OUTFILE "\n";
    print '.';
  }

  print "\n";
  close(OUTFILE);

  return(1);

} # end writePeptideListFile



###############################################################################
# writeIdentificationListTemplateFile
###############################################################################
sub writeIdentificationListTemplateFile {
  my %args = @_;
  my $output_file = $args{'output_file'} || die("No output file provided");
  my $identification_list = $args{'identification_list'}
    || die("No output identification_list provided");

  print "Writing output cache template file '$output_file'...\n";

  #### Open and write header
  open(OUTFILE,">$output_file")
    || die("ERROR: Unable to open '$output_file' for write");

  #### Write out the column names
  my @column_names = qw ( search_batch_id spectrum_query peptide_accession
    peptide_sequence preceding_residue modified_peptide_sequence
    following_residue charge probability massdiff protein_name );

  print OUTFILE join("\t",@column_names)."\n";

  print "  - writing ".scalar(@{$identification_list})." peptides\n";

  my $counter = 0;
  foreach my $identification ( @{$identification_list} ) {
    print OUTFILE join("\t",@{$identification})."\n";
    $counter++;
    print "$counter... " if ($counter % 1000 == 0);
  }

  print "\n";
  close(OUTFILE);

  return(1);

} # end writeIdentificationListTemplateFile



###############################################################################
# readIdentificationListTemplateFile
###############################################################################
sub readIdentificationListTemplateFile {
  my %args = @_;
  my $input_file = $args{'input_file'} || die("No input file provided");
  my $identification_list = $args{'identification_list'}
    || die("No output identification_list provided");

  print "Reading cache template file '$input_file'...\n";

  #### Open and write header
  open(INFILE,$input_file)
    || die("ERROR: Unable to open '$input_file'");

  my $counter = 0;
  my $line;
  while ($line = <INFILE>) {
    chomp($line);
    my @columns = split(/\t/,$line);
    push(@{$identification_list},\@columns);
    $counter++;
    print "$counter... " if ($counter % 1000 == 0);
  }

  print "\n";
  close(INFILE);

  print "  - read ".scalar(@{$identification_list})." peptides\n";

  return(1);

} # end readIdentificationListTemplateFile



###############################################################################
# writeIdentificationListFile
###############################################################################
sub writeIdentificationListFile {
  my %args = @_;
  my $output_file = $args{'output_file'} || die("No output file provided");
  my $identification_list = $args{'identification_list'}
    || die("No output identification_list provided");
  my $ProteinProphet_data = $args{'ProteinProphet_data'}
    || die("No ProteinProphet_data provided");
  my $spectral_library_data = $args{'spectral_library_data'};
  my $P_threshold = $args{'P_threshold'}
    || die("No P_threshold provided");
  my $best_prob_per_pep;
  # if best_probs_from_protxml is set, this arg is undefined
  ($best_prob_per_pep = $args{'best_prob_per_pep'})
    || print "INFO: no best_prob_per_pep passed to writeIdentificationListFile\n";

  print "Writing output combined cache file '$output_file'...\n";

  #### Open and write header
  open(OUTFILE,">$output_file")
    || die("ERROR: Unable to open '$output_file' for write");

  #### Write out the column names
  my @column_names = qw ( search_batch_id spectrum_query peptide_accession
    peptide_sequence preceding_residue modified_peptide_sequence
    following_residue charge probability massdiff protein_name adjusted_probability
    n_adjusted_observations n_sibling_peptides );

  print OUTFILE join("\t",@column_names)."\n";

  print "  - writing ".scalar(@{$identification_list})." peptides\n";

  my $counter = 0;
  my %consensus_lib = ( found => [], missing => [] );

  #print "ProteinProphet data:\n";
  #while ((my $pep, my $info) = each ( %{$ProteinProphet_data} )) {
    #print "  $pep $info->{nsp_adjusted_probability}\n";
  #}

  foreach my $identification ( @{$identification_list} ) {

    my $charge = $identification->[7];
    my $peptide_sequence = $identification->[3];
    my $modified_peptide = $identification->[5];
    my $spectrast_formatted_sequence = $modified_peptide . '/' . $charge;

    #### Grab the ProteinProphet information
    my $initial_probability;
    my $adjusted_probability = '';
    my $n_adjusted_observations = '';
    my $n_sibling_peptides = '';
    my $probability_adjustment_factor;
    my $pep_key = '';
    my $diff_is_great=0;
    if ($ProteinProphet_data->{"${charge}-$modified_peptide"}) {
      $pep_key = "${charge}-$modified_peptide";
    } elsif ($ProteinProphet_data->{$peptide_sequence}) {
      $pep_key = $peptide_sequence;
    } else {
      print "WARNING: Did not find ProtProph info for keys ".
	"$peptide_sequence or '${charge}-$modified_peptide'\n";
    }
    if ($pep_key) {
      my $info = $ProteinProphet_data->{$pep_key};
      if ($best_prob_per_pep) {
        # subtract .001 since DS does this in ProteinProphet
        $initial_probability = $best_prob_per_pep->{$pep_key} - .001;
        if (0) {
          my $diff = $initial_probability-$info->{initial_probability};
          $diff_is_great = ($diff > .0011 || $diff < -.0011);
          if ($diff_is_great) {  # 12/31/08 tmf debugging
            printf "Orig init prob: %.5f New init prob: %.5f Diff: %.5f %s\n",
               $info->{initial_probability},
               $initial_probability,
               $diff, $pep_key;
          }
        }
      } else {
        $initial_probability = $info->{initial_probability};
      }
      $adjusted_probability = $info->{nsp_adjusted_probability};
      $n_adjusted_observations = $info->{n_adjusted_observations};
      $n_sibling_peptides = $info->{n_sibling_peptides};
      push(@{$identification},$adjusted_probability,$n_adjusted_observations,$n_sibling_peptides);
      if ($initial_probability) {
	$probability_adjustment_factor = $adjusted_probability / $initial_probability;
      }
    }

    #### If we are operating with a master_ProteinProphet_file, then
    #### try a radical thing. Multiply the PepPro and ProPro probability.
    #### This probably really isn't correct, but maybe it'll be close.
    if ($OPTIONS{master_ProteinProphet_file}) {
      my $probability = $identification->[8];
      my $adjusted_probability = $identification->[11];
      if ($adjusted_probability && $probability_adjustment_factor) {

	#### Depresses probabilities too much
	#$probability = $probability * $adjusted_probability;

	#### If the adjusted probability is 1.0, then give probabilities a big boost
	#if ($adjusted_probability > 0.9999) {
	#  $probability = 1.0 - ( ( 1.0 - $probability ) / 3.0 );
	#  #### Although don't let it be less the adjustment to the top one
	#  if ( $probability < $probability * $probability_adjustment_factor) {
	#    $probability = $probability * $probability_adjustment_factor;
	#  }
	##### Else just apply the adjustment factor given to the top one
	#} else {
	#  $probability = $probability * $probability_adjustment_factor;
	#}

	#### Apply the adjustment factor given to the top one
	$probability = $probability * $probability_adjustment_factor;

	#### Newer ProteinProphet downgrades initial_probability 1.000 to 0.999
	#### to help adjustment code. Because of this, sometimes probabilities
	#### here can drift slightly over 1.000. Don't allow that.
	$probability = 1 if ($probability > 1);

	#### If there is spectral library information, look at that
	if ($spectral_library_data && $spectrast_formatted_sequence) {
	  if ($spectral_library_data->{$spectrast_formatted_sequence}) {
	    #print "$peptide_sequence\t$probability\t$spectral_library_data->{$peptide_sequence}\n";

      # This adds a 15th column, which gums up the works during the load
#	    $identification->[14] = $spectral_library_data->{$spectrast_formatted_sequence};
      push @{$consensus_lib{found}}, $spectrast_formatted_sequence;
	  } else {
	    # print "$peptide_sequence\t$probability\t($spectrast_formatted_sequence)\t not in lib \n";
      push @{$consensus_lib{missing}}, $spectrast_formatted_sequence;
	    #### If it's not in the library, kill it
	    $probability = 0.5;
	  }
	}

  $identification->[8] = $probability;

      } else {
	print "WARNING: No adjusted probability for $charge-$modified_peptide\n";
      }
    }

    #### If the probability does not meet the threshold, drop it
    my $probability = $identification->[8];
    if ($probability >= $P_threshold) {
      print OUTFILE join("\t",@{$identification})."\n";
      $counter++;
      print "$counter... " if ($counter % 1000 == 0);
    } else {
      ### tmf debugging 12/08
      if ($diff_is_great) { print "REJECTED!!!\n"; }
    }
  }

  if ( $consensus_lib{found} || $consensus_lib{missing} ) {
    # Must have used spectrast lib
    print "Filtered vs. consensus library, found " . scalar( @{$consensus_lib{found}} ) . ',  ' .  scalar( @{$consensus_lib{missing}} ) . " were missing\n";
  }
  print "\n";
  close(OUTFILE);

  return(1);

} # end writeIdentificationListFile



###############################################################################
# readSpectralLibraryPeptides
###############################################################################
sub readSpectralLibraryPeptides {
  my %args = @_;
  my $input_file = $args{'input_file'} || die("No input file provided");

  #### Return if library not available
  if ( ! -e $input_file ) {
    print "WARNING: Spectral library '$input_file' not found!\n";
    return;
  }

  print "Reading consensus spectral library file '$input_file'...\n";

  #### Open library file
  open(INFILE,$input_file)
    || die("ERROR: Unable to open '$input_file'");


  #### Verify that the head is as we expect
  my $line;
  while ($line = <INFILE>) {
    if ($line =~ /^\#\#\# ===/) {
      last;
    }
    if ($line !~ /^\#\#\#/) {
      die("ERROR: Unexpected format reading spectral library '$input_file'");
    }
  }

  my $peptides;
  my $n_peptides;
  my ($peptide_sequence,$probability);
  my $counter;

  #### Read file minimally, skimming out the peptide information
  while ($line = <INFILE>) {
    chomp($line);
    if ($line =~ /^Name: ([^\/]+\/\d)/) {
      $peptide_sequence = $1;
    }
    if ($line =~ /^Comment: .+ Prob=([\d\.]+)/) {
      $probability = $1;
    }
    if ($line =~ /^NumPeaks/) {
      if ($peptides->{$peptide_sequence}) {
	if ($probability > $peptides->{$peptide_sequence}) {
	  $peptides->{$peptide_sequence} = $probability;
	  #print "$peptide_sequence = $probability\n";
	}
      } else {
	$peptides->{$peptide_sequence} = $probability;
	#print "$peptide_sequence = $probability\n";
	$n_peptides++;
      }
    }

    #$counter++;
    #print "$counter... " if ($counter % 1000 == 0);

  }

  close(INFILE);

  print "  - read $n_peptides peptides\n";

  return($peptides);

} # end readSpectralLibraryPeptides