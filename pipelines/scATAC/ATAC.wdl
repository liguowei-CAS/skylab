version 1.0

workflow ATAC {
 input {
   #fastq inputs
   File fastq_gzipped_input_read1
   File fastq_gzipped_input_read2

   # trimming options
   Int min_length
   Int quality_cutoff
   String adapter_seq_read1
   String adapter_seq_read2

   # fasta for alignment
   File reference_fasta

   # filtering options
   Int min_map_quailty
   Int max_fragment_length

   # output prefix/base name for all intermediate files and pipeline outputs
   String output_base_name
 }

  call TrimAdapters {
    input:
      fastq_input_read1 = fastq_gzipped_input_read1,
      fastq_input_read2 = fastq_gzipped_input_read2,
      min_length = min_length,
      quality_cutoff = quality_cutoff,
      adapter_seq_read1 = adapter_seq_read1,
      adapter_seq_read2 = adapter_seq_read2,
      output_base_name = output_base_name
  }

  call CreateUnmappedBam as CreateUnmappedBamRead1 {
    input:
      fastq_input = TrimAdapters.fastq_trimmed_adapter_output_read1,
      output_base_name = output_base_name + ".R1"
  }

  call CreateUnmappedBam as CreateUnmappedBamRead2 {
    input:
      fastq_input = TrimAdapters.fastq_trimmed_adapter_output_read2,
      output_base_name = output_base_name + ".R2"
  }

  call Align {
    input:
      fastq_input_read1 = TrimAdapters.fastq_trimmed_adapter_output_read1,
      fastq_input_read2 = TrimAdapters.fastq_trimmed_adapter_output_read2,
      reference_fasta = reference_fasta,
      output_base_name = output_base_name
  }

  call Sort as SortCoordinateOrder {
    input:
      bam_input = Align.bam_align_output,
      sort_order = "coordinate",
      output_base_name = output_base_name
  }

  call FilterMarkDuplicates {
    input:
      bam_input = SortCoordinateOrder.bam_sort_output,
      output_base_name = output_base_name
  }

  call FilterMinMapQuality{
    input:
      bam_input = FilterMarkDuplicates.bam_remove_dup_output,
      min_map_quality = min_map_quailty,
      output_base_name = output_base_name
  }

  call FilterMaxFragmentLength {
    input:
      bam_input = FilterMinMapQuality.bam_filter_mapq_output,
      max_fragment_length = max_fragment_length,
      output_base_name = output_base_name
  }

  call FilterMitochondrialReads {
    input:
      bam_input = FilterMaxFragmentLength.bam_filter_fragment_length_output,
      output_base_name = output_base_name
  }

  call Sort as SortQueryName {
    input:
      bam_input = FilterMitochondrialReads.bam_no_chrM_reads_output,
      sort_order = "queryname",
      output_base_name = output_base_name
  }
}

task TrimAdapters {
  input {
     Int min_length
     Int quality_cutoff
     File fastq_input_read1
     File fastq_input_read2
     String adapter_seq_read1
     String adapter_seq_read2
     String output_base_name
     String docker_image = "quay.io/broadinstitute/cutadapt:1.18"
  }

  # input file size
  Float input_size = size(fastq_input_read1, "GB") + size(fastq_input_read2, "GB")

  # output names for trimmed reads
  String fastq_trimmed_adapter_output_name_read1 = output_base_name + ".R1.trimmed_adapters.fastq.gz"
  String fastq_trimmed_adapter_output_name_read2 = output_base_name + ".R2.trimmed_adapters.fastq.gz"

  # using cutadapt to trim off sequence adapters
  command <<<
    set -euo pipefail

    # fastq's, "-f", -A for paired adapters read 2"
    cutadapt \
      -f fastq \
      --minimum-length ~{min_length} \
      --quality-cutoff ~{quality_cutoff} \
      --adapter ~{adapter_seq_read1} \
      -A ~{adapter_seq_read2} \
      --output ~{fastq_trimmed_adapter_output_name_read1} \
      --paired-output ~{fastq_trimmed_adapter_output_name_read2} \
      ~{fastq_input_read1} ~{fastq_input_read2}
  >>>

  # use docker image for given tool cutadapat
  runtime {
    docker: docker_image
    # if the input size is less than 1 GB adjust to min input size of 1 GB
    # disks should be set to 2 * input file size
    disks: "local-disk " + ceil(2 * (if input_size < 1 then 1 else input_size)) + " HDD"
    cpu: 1
    memory: "3.5 GB"
  }

  output {
    File fastq_trimmed_adapter_output_read1 = fastq_trimmed_adapter_output_name_read1
    File fastq_trimmed_adapter_output_read2 = fastq_trimmed_adapter_output_name_read2
    File monitoring_log = "monitoring.log"
  }
}

task CreateUnmappedBam   {
  input {
    File fastq_input
    String output_base_name
    String docker_image = "quay.io/broadinstitute/picard:2.18.23"
  }

  # input file size
  Float input_size = size(fastq_input, "GB")

  # output names for bam with
  String unmapped_bam_output_name = output_base_name + ".unmapped.bam"

  command <<<
    set -euo pipefail

    # create an unmapped bam
    java -jar /picard-tools/picard.jar FastqToSam \
      FASTQ=~{fastq_input} \
      SAMPLE_NAME=~{output_base_name} \
      OUTPUT=~{unmapped_bam_output_name}
  >>>

  # use docker image for given tool cutadapat
  runtime {
    docker: docker_image
    # if the input size is less than 1 GB adjust to min input size of 1 GB
    # disks should be set to 2.25 * input file size
    disks: "local-disk " + ceil(2.25 * (if input_size < 1 then 1 else input_size)) + " HDD"
    cpu: 1
    memory: "3.5 GB"
  }

  output {
    File unmapped_bam_output = unmapped_bam_output_name
    File monitoring_log = "monitoring.log"
  }
}

# FIXME
# map the reads using bwa
task Align {
  input {
    File fastq_input_read1
    File fastq_input_read2
    File reference_fasta
    String output_base_name
    String docker_image = "hisplan/snaptools:latest"
  }

  # output name for sorted bam
  String bam_align_output_name = output_base_name + ".aligned.bam"

  # input file size
  Float input_size = size(fastq_input_read1, "GB") + size(fastq_input_read2, "GB") + size(reference_fasta, "GB")

  # sort with samtools
  command <<<
    set -euo pipefail

    snaptools align-paired-end \
      --input-fastq1=~{fastq_input_read1} \
      --input-fastq2=~{fastq_input_read2} \
      --input-reference=~{reference_fasta} \
      --output-bam=~{output_base_name} \
      --aligner=bwa \
      --path-to-aligner=/tools/bwa \
      --read-fastq-command=zcat \
      --min-cov=0 \
      --tmp-folder=./ \
      --overwrite=TRUE
  >>>

  runtime {
    docker: docker_image
    # if the input size is less than 1 GB adjust to min input size of 1 GB
    # disks should be set to 3.25 * input file size
    disks: "local-disk " + ceil(3.25 * (if input_size < 1 then 1 else input_size)) + " HDD"
    cpu: 1
    memory: "3.5 GB"
  }

  output {
    File bam_align_output = bam_align_output_name
    File monitoring_log = "monitoring.log"
  }

}

task Sort {
  input {
    File bam_input
    String sort_order
    String output_base_name
    String docker_image = "quay.io/broadinstitute/picard:2.18.23"
  }

  # output name for sorted bam
  String bam_sort_output_name = output_base_name + ".sorted.bam"

  # input file size
  Float input_size = size(bam_input, "GB")

  # sort with samtools
  command <<<
    set -euo pipefail

    java -jar /picard-tools/picard.jar SortSam \
      INPUT=~{bam_input} \
      SORT_ORDER=~{sort_order} \
      MAX_RECORDS_IN_RAM=300000 \
      OUTPUT=~{bam_sort_output_name}
  >>>

  runtime {
    docker: docker_image
    # if the input size is less than 1 GB adjust to min input size of 1 GB
    # disks should be set to 3.25 * input file size
    disks: "local-disk " + ceil(3.25 * (if input_size < 1 then 1 else input_size)) + " HDD"
    cpu: 1
    memory: "3.5 GB"
  }

  output {
    File bam_sort_output = bam_sort_output_name
    File monitoring_log = "monitoring.log"
  }
}

# filter bam by removing duplicates
task FilterMarkDuplicates {
  input {
    File bam_input
    String output_base_name
    String docker_image = "quay.io/broadinstitute/picard:2.18.23"
  }

  # output namefor mark duplicates
  String bam_remove_dup_output_name = output_base_name + ".filtered.duplicates.bam"
  String metric_remove_dup_output_name = output_base_name + ".filtered.duplicate_metrics"

  # input file size
  Float input_size = size(bam_input, "GB")

  command <<<
    set -euo pipefail

    java -jar /picard-tools/picard.jar MarkDuplicates \
      INPUT=~{bam_input} \
      OUTPUT=~{bam_remove_dup_output_name} \
      METRICS_FILE=~{metric_remove_dup_output_name}
  >>>

  runtime {
     docker: docker_image
     # if the input size is less than 1 GB adjust to min input size of 1 GB
     # disks should be set to 2 * input file size
     disks: "local-disk " + ceil(2 * (if input_size < 1 then 1 else input_size)) + " HDD"
     cpu: 1
     memory: "3.5 GB"
  }

  output {
    File bam_remove_dup_output = bam_remove_dup_output_name
    File metric_remove_dup_output = metric_remove_dup_output_name
    File monitoring_log = "monitoring.log"
  }
}

# filter bam with a minimum mapping quality
task FilterMinMapQuality {
  input {
    File bam_input
    Int min_map_quality
    String output_base_name
    String docker_image = "quay.io/broadinstitute/samtools:1.9"
  }

  # output name for filtered read
  String bam_filter_mapq_output_name = output_base_name + ".filtered.min_map_quality.bam"

  # input file size
  Float input_size = size(bam_input, "GB")

  command <<<
    set -euo pipefail

    # filter for a map quality
    # -b output is bam, -h include header, -q reads with mapping quality >=
    samtools view \
      -bhq~{min_map_quality} \
      ~{bam_input} \
      > ~{bam_filter_mapq_output_name}
  >>>

  runtime {
    docker: docker_image
    # if the input size is less than 1 GB adjust to min input size of 1 GB
    # disks should be set to 2 * input file size
    disks: "local-disk " + ceil(2 * (if input_size < 1 then 1 else input_size)) + " HDD"
    cpu: 1
    memory: "3.5 GB"
  }

  output {
    File bam_filter_mapq_output = bam_filter_mapq_output_name
    File monitoring_log = "monitoring.log"
  }
}

# filter bam with a max fragment length
task FilterMaxFragmentLength {
  input {
    File bam_input
    Int max_fragment_length
    String output_base_name
    String docker_image = "broadinstitute/gatk:4.1.2.0"
  }

  # output name for filtered read
  String bam_filter_fragment_length_output_name = output_base_name + ".filtered.max_fragment_length.bam"

  # input file size
  Float input_size = size(bam_input, "GB")

  command <<<
    set -euo pipefail

    gatk PrintReads \
      --input=~{bam_input} \
      --read-filter FragmentLengthReadFilter --max-fragment-length ~{max_fragment_length} \
      --output=~{bam_filter_fragment_length_output_name}
  >>>

  runtime {
    docker: docker_image
    # if the input size is less than 1 GB adjust to min input size of 1 GB
    # disks should be set to 2 * input file size
    disks: "local-disk " + ceil(2 * (if input_size < 1 then 1 else input_size)) + " HDD"
    cpu: 1
    memory: "3.5 GB"
  }

  output {
    File bam_filter_fragment_length_output = bam_filter_fragment_length_output_name
    File monitoring_log = "monitoring.log"
  }
}

# split the bam into read containing only and not containing any mitochondrial reads
task FilterMitochondrialReads {
  input {
    File bam_input
    String output_base_name
    String docker_image = "quay.io/broadinstitute/samtools:1.9"
  }

  # output name for sorted bam
  String bam_chrM_reads_output_name = output_base_name + ".filtered.mitochondrial_reads.bam"
  String bam_no_chrM_reads_output_name = output_base_name +".filtered.no_mitochondrial_reads.bam"

  # input file size
  Float input_size = size(bam_input, "GB")

  # ChrM: mitochondrial chromosome
  command <<<
    set -euo pipefail

    # get bam w/o chrM
    list_chrs=`samtools view -H ${input_bam} | grep chr | cut -f2 | sed 's/SN://g' | grep -v 'chrM\|_'`
    samtools view \
      -b -q 30 -f 0x2 \
      ~{bam_input} \
      -o ~{bam_no_chrM_reads_output_name} `echo $list_chrs`

    #get bam with only chrM
    samtools view  \
      ~{bam_input} \
      ChrM \
      > ~{bam_chrM_reads_output_name}
  >>>

  runtime {
    docker: docker_image
    # if the input size is less than 1 GB adjust to min input size of 1 GB
    # disks should be set to 2 * input file size
    disks: "local-disk " + ceil(2 * (if input_size < 1 then 1 else input_size)) + " HDD"
    cpu: 1
    memory: "3.5 GB"
  }

  output {
    File bam_no_chrM_reads_output = bam_no_chrM_reads_output_name
    File bam_chrM_reads_output = bam_chrM_reads_output_name
    File monitoring_log = "monitoring.log"
  }
}

