# The main entry point of your workflow.
# After configuring, running snakemake -n in a clone of this repository should successfully execute a dry-run of the workflow.


import glob
import pandas as pd
from snakemake.utils import validate, min_version
from Bio import SeqIO
from Bio.SeqRecord import SeqRecord
from Bio.Seq import Seq


##### load config and sample sheets #####


configfile: "config.yaml"
# report: "report/workflow.rst"

validate(config, schema="schemas/config.schema.yaml")

if config['samplesheet'] != "":
    samples = pd.read_csv(config['samplesheet']).set_index("ID", drop=False)
    validate(samples, schema="schemas/samples.schema.yaml")
    SAMPLES = dict(zip(samples["Name"], samples["ID"]))    
else:
    samples = None
    SAMPLES = {}



# LIBRARY_FASTA = bowtie
# LIBRARY_BASENAME = "bowtie/" + os.path.splitext(os.path.basename(LIBRARY_FASTA))[0]
# LIBRARY_INDEX_DONEFILE = LIBRARY_BASENAME + ".done"

THREADS = config['threads']
FASTQ_DIR = config['fastq_dir']



# Allow users to fix the underlying OS via singularity.
singularity: "docker://continuumio/miniconda3"


# include: "rules/other.smk"

wildcard_constraints:
    directory=".+\/",
    sample="[^\/]+"


rule all:
    input:
        "outs/feature_counts.txt",
        "outs/read_stats.csv",
        "outs/featurebarcode-qc-report.html"
    run:
        print("workflow complete!")

rule create_report:
    input:
        counts = "outs/feature_counts.txt",
        stats = "outs/read_stats.csv"
    output:
        "outs/featurebarcode-qc-report.html"
    script:
        "report/featurebarcode-qc-report.Rmd"

rule get_read_stats:
    input:
        trim = expand("outs/trim/{sample}_R1.fastq.gz", sample=SAMPLES.keys()),
        alns = expand("outs/alns/{sample}.bam", sample=SAMPLES.keys()),
        counts = expand("outs/feature_counts/{sample}.txt", sample=SAMPLES.keys()),
        pdna_trim = "outs/pdna/trim/pDNA.fastq.gz",
        pdna_alns = "outs/pdna/alns/pDNA.bam",
        pdna_counts = "outs/pdna/feature_counts/pDNA.txt"
    output:
        "outs/read_stats.csv"
    params:
        samplesheet = lambda wildcards: "--samplesheet " + config['samplesheet'] if samples is not None else "",
        pdna_fastq = lambda wildcards: "--pdna-fastq " + config['pdna_fastq'] if config['pdna_fastq'] is not "" else "",
        fastq_dir = lambda wildcards: "--fastq-dir " + config['fastq_dir'] if config['fastq_dir'] is not "" else ""
    shell:
        "python scripts/read_stats.py {output} {params.samplesheet} "
        "{params.pdna_fastq} {params.fastq_dir}"

rule combine_feature_counts:
    input:
        expand("outs/feature_counts/{sample}.txt",sample=SAMPLES),
        "outs/pdna/feature_counts/pDNA.txt"
    output: "outs/feature_counts.txt"
    params:
        input_string = lambda wildcards, input: ','.join(input)
        # input_string = ','.join(expand("outs/feature_counts/{sample}.txt", sample=SAMPLES.keys()) +
        #     ["outs/pdna/feature_counts/pDNA.txt"])
    shell:
        "python scripts/combine_feature_counts.py {params.input_string} {output}"


def get_paired_fqs(wildcards):
    sample_id = SAMPLES[wildcards.sample]
    r1 = glob.glob(os.path.join(FASTQ_DIR, "**", sample_id + "_*R1_*.fastq.gz"),
        recursive=True)
    r2 = glob.glob(os.path.join(FASTQ_DIR, "**", sample_id + "_*R2_*.fastq.gz"), 
        recursive=True)
    if len(r1) == 0:
        raise ValueError(sample_id + "has no matching input fastq file")
    if len(r1) > 1:
        raise ValueError(sample_id + "has more than one matching input fastq file")
    return {"read1": r1[0], "read2": r2[0]}
    

rule extract_umi_pdna:
    input: config['pdna_fastq']
    output: "outs/pdna/umi/pDNA.fastq.gz"
    shell:
        "umi_tools extract --extract-method string "
        "--bc-pattern NNNNNNNNNN "
        "--stdin {input} --stdout {output}"

rule trim_reads_pdna:
    input: "outs/pdna/umi/pDNA.fastq.gz"
    output: "outs/pdna/trim/pDNA.fastq.gz"
    threads: THREADS
    params:
        u6_promoter = config['trimming']['u6_promoter'],
        sgrna_scaffold = config['trimming']['sgrna_scaffold'],
        error_rate = config['trimming']['error_rate']
    shell:
        "cutadapt -j {threads} -m 18 --discard-untrimmed "
        "-g \"{params.u6_promoter}...{params.sgrna_scaffold};max_error_rate={params.error_rate}\" "
        "-o {output} {input}"

rule feature_counts_pdna:
    input:
        bam="outs/pdna/alns/pDNA.bam",
        bamidx="outs/pdna/alns/pDNA.bam.bai",
    output:
        counts="outs/pdna/feature_counts/pDNA.txt",
        log="outs/pdna/feature_counts/pDNA.log"
    shell:
        "umi_tools count --per-contig --method {config[dedup_method]} "
        "--stdin={input.bam} --stdout={output.counts} --log={output.log}"


rule bowtie_align_pdna:
    input:
        donefile = "bowtie/feature_ref.done",
        fastq = "outs/pdna/trim/pDNA.fastq.gz"
    output:
        sam = "outs/pdna/alns/pDNA.sam"
    threads: THREADS
    params:
        index = "bowtie/feature_ref"
    shell:
        "bowtie --sam -v 1 -y -a --best -t -p {threads} {params.index} {input.fastq} {output.sam}"


rule trim_reads:
    input: unpack(get_paired_fqs)
    output:
        read1 = "outs/trim/{sample}_R1.fastq.gz",
        read2 = "outs/trim/{sample}_R2.fastq.gz"
    threads: THREADS
    params:
        tso = config['trimming']['tso'],
        sgrna_scaffold = config['trimming']['sgrna_scaffold'],
        error_rate = config['trimming']['error_rate']
    shell:
        "cutadapt -j {threads} --discard-untrimmed -m 18 --pair-filter=first "
        "-g \"{params.tso}...{params.sgrna_scaffold};max_error_rate={params.error_rate}\" "
        "-o {output.read2} -p {output.read1} {input.read2} {input.read1}"

rule extract_umi:
    input:
        read1="outs/trim/{sample}_R1.fastq.gz",
        read2="outs/trim/{sample}_R2.fastq.gz"
    output:
        "outs/umi/{sample}.fastq.gz"
    params:
        whitelist = config['cell_barcode']['whitelist']
    shell:
        "umi_tools extract --extract-method regex --read2-stdout "
        "--bc-pattern '(?P<cell_1>.{{16}})(?P<umi_1>.{{12}})' "
        "--bc-pattern2 '(?P<discard_1>.*).{{20}}' "
        "--stdin {input.read1} --read2-in {input.read2} --stdout {output} "
        "--filter-cell-barcode --whitelist  {params.whitelist}"


rule make_library_fasta:
    input:
        feature_ref = config['feature_ref']
    output:
        fasta = "bowtie/feature_ref.fa"
    run:
        feature_ref = pd.read_csv(input.feature_ref).set_index("id", drop=False)
        feature_seqs = [SeqRecord(Seq(s), id=i, description='')
            for s, i in zip(feature_ref['sequence'], feature_ref['id'])]
        with open (output.fasta, 'w') as fa:
            SeqIO.write(feature_seqs, fa, "fasta")


rule bowtie_build:
    input:
        fasta = "bowtie/feature_ref.fa"
    output:
        touch("bowtie/feature_ref.done")
    params:
        basename = "bowtie/feature_ref"
    shell:
        "bowtie-build {input.fasta} {params.basename}"

rule bowtie_align:
    input:
        donefile = "bowtie/feature_ref.done",
        fastq = "outs/umi/{sample}.fastq.gz"
    output:
        sam = "outs/alns/{sample}.sam"
    threads: THREADS
    params:
        index = "bowtie/feature_ref"
    shell:
        "bowtie --sam -v 1 -y -a --best -t -p {threads} {params.index} {input.fastq} {output.sam}"

rule feature_counts:
    input:
        bam="outs/alns/{sample}.bam",
        bamidx="outs/alns/{sample}.bam.bai",
    output:
        counts="outs/feature_counts/{sample}.txt",
        log="outs/feature_counts/{sample}.log"
    shell:
        "umi_tools count --per-contig --per-cell --method {config[dedup_method]} "
        "--stdin={input.bam} --stdout={output.counts} --log={output.log}"


rule sam_to_bam_sort:
    input:
        "{directory}{sample}.sam"
    output:
        "{directory}{sample}.bam"
    threads: THREADS
    shell:
        "samtools view -b --threads {threads} {input} | "
        "samtools sort -@ {threads}  -o {output}"


rule samtools_index:
    input:
        "{directory}{sample}.bam"
    output:
        "{directory}{sample}.bam.bai"
    threads: THREADS
    shell:
        "samtools index -@ {threads} {input}"
