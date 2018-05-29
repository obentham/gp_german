#!/bin/bash -x
# Recipe to build a kaldi ASR system on the Globalphone German corpus

# source 2 files to get some environment variables
. ./cmd.sh
. ./path.sh
# The path.sh file has a  variable that points to the kaldi source code.

# initialize the stage variable
stage=0

# Use the following command to run this script starting at stage 2:
# nohup ./run.sh --stage 2 > run_stage_2.log &

# source a file that will handle variables
. ./utils/parse_options.sh

# Set the locations of the GlobalPhone corpus and language models
gp_corpus=/mnt/corpora/Globalphone/DEU_ASR003_WAV
gp_lexicon=/mnt/corpora/Globalphone/GlobalPhoneLexicons/German/German-GPDict.txt

# Set a variable that points to a URL for a standard German language model
gp_lm=http://www.csl.uni-bremen.de/GlobalPhone/lm/GE.3gram.lm.gz

#  set a variable to the directory where  data preparation will take place
tmpdir=data/local/tmp/gp/german

# The number of jobs you can run will depend on the system
decoding_jobs=5
training_jobs=56

# global phone data prep
if [ $stage -le 0 ]; then
    mkdir -p $tmpdir/lists

    # get list of globalphone .wav files
        find $gp_corpus/adc -type f -name "*.wav" > $tmpdir/lists/wav.txt

	# get list of files containing  transcripts
    find $gp_corpus/trl -type f -name "*.trl" > $tmpdir/lists/trl.txt

    for fld in dev eval train; do
	# each fold will have a separate working directory
	mkdir -p $tmpdir/$fld/lists

	# the conf/dev_spk.list file has a list of the speakers in the dev fold.
	# the conf/train_spk.list file has a list of the speakers in the training fold.
	# the conf/eval_spk.list file has a list of the speakers in the testing fold.
	# The following command will get the list .wav files restricted to only the speakers in the current fold.
	grep \
	    -f conf/${fld}_spk.list  $tmpdir/lists/wav.txt  > \
	    $tmpdir/$fld/lists/wav.txt

	# Similarly for the .trl files that contain transliterations.
	grep \
	    -f conf/${fld}_spk.list  $tmpdir/lists/trl.txt  > \
	    $tmpdir/$fld/lists/trl.txt

	# write a file with a file-id to utterance map. 
	local/get_prompts.pl $fld

	# Acoustic model training requires 4 files containing maps:
	# 1. wav.scp
	# 2. utt2spk
	# 3. spk2utt
	# 4. text

	# make the required acoustic model training lists
	# This is first done in the temporary working directory.
	local/make_lists.pl $fld

	utils/fix_data_dir.sh $tmpdir/$fld/lists

	# consolidate  data lists into files under data
	mkdir -p data/$fld
	for x in wav.scp text utt2spk; do
	    cat $tmpdir/$fld/lists/$x | sort >> data/$fld/$x
	done

	# The spk2utt file can be generated from the utt2spk file. 
	utils/utt2spk_to_spk2utt.pl data/$fld/utt2spk | sort > data/$fld/spk2utt

	utils/fix_data_dir.sh data/$fld
    done
fi
exit
# Process the pronouncing dictionary
if [ $stage -le 1 ]; then
    mkdir -p $tmpdir/dict

    # The following  script is part of the original Globalphone kaldi recipe
    local/gp_norm_dict_GE.pl -i $gp_lexicon | sort -u > $tmpdir/dict/lexicon.txt

    # Make some lists related to the lexicon
    # Including:
    # 1. A list of non-silence phones,
    # 2. A list of silence phones,
     # 3. A list of silence related questions for model clustering.
    # 4. A list of optional silence symbols
    local/prepare_dict.sh
    # The prepared lexicon is also written.
fi

if [ $stage -le 2 ]; then
    # prepare lang directory
    # The lang directory will contain several files.
    # Including the finite state transducer file for the lexicon and grammar.
    # The lexicon fst will be stored in L.fst.
    # The grammar (ngram language model) will be stored in G.fst.
    # G.fst will be generated in a later step.
    utils/prepare_lang.sh \
	--position-dependent-phones true data/local/dict "<UNK>" \
	data/local/lang_tmp data/lang
fi

if [ $stage -le 3 ]; then
    # prepare the n-gram language model
    mkdir -p data/local/lm

        # get the reference lm from Bremen
    wget \
	-O data/local/lm/threegram.arpa.gz \
	$gp_lm

    # The following command creates an lm with the training  data:
    #local/prepare_lm.sh

    # Now generate the G.fst file from the lm.
    # Notice that it will be stored under data/lang_test.
    utils/format_lm.sh \
	data/lang data/local/lm/threegram.arpa.gz data/local/dict/lexicon.txt \
	data/lang_test
fi

if [ $stage -le 4 ]; then
    # Create ConstArpaLm format language model for full 3-gram and 4-gram LMs
    utils/build_const_arpa_lm.sh \
	data/local/lm/threegram.arpa.gz \
	data/lang \
	data/lang_test
fi

# extract acoustic features
if [ $stage -le 5 ]; then
    # This stage will create the exp directory where most of the rest of the work will take place.
    # The feature files will be stored under plp_pitch
    # plp and pitch features are extracted.
    for fld in dev eval train ; do
	steps/make_plp_pitch.sh \
	    --cmd run.pl --nj $training_jobs data/$fld exp/make_plp_pitch/$fld \
	    plp_pitch

	utils/fix_data_dir.sh data/$fld

	steps/compute_cmvn_stats.sh data/$fld exp/make_plp_pitch/$fld plp_pitch

	utils/fix_data_dir.sh data/$fld
    done
fi
exit
if [ $stage -le 6 ]; then
    echo "Starting  monophone training in exp/mono on" `date`
    steps/train_mono.sh \
	--nj $training_jobs \
	--cmd run.pl \
	data/train \
	data/lang \
	exp/mono || exit 1;
fi

if [ $stage -le 7 ]; then
    # align with monophones
    steps/align_si.sh \
	--nj $training_jobs \
	--cmd run.pl \
	data/train \
	data/lang \
	exp/mono \
	exp/mono_ali || exit 1;
fi

if [ $stage -le 8 ]; then
    mkdir -p exp/mono/graph
    (
	utils/mkgraph.sh \
	data/lang_test \
	exp/mono \
	exp/mono/graph

	for fld in dev eval; do
	    steps/decode.sh \
		--nj $decoding_jobs \
		--cmd "$decode_cmd" \
		exp/mono/graph \
		data/$fld \
		exp/mono/decode_${fld}
	done
    ) &
fi

if [ $stage -le 9 ]; then
    echo "Starting  triphone training in exp/tri1 on" `date`
    steps/train_deltas.sh \
	--cluster-thresh 100 \
	--cmd run.pl \
	3100 \
	50000 \
	data/train \
	data/lang \
	exp/mono_ali \
	exp/tri1 || exit 1;
fi

if [ $stage -le 10 ]; then
    # align with triphones
    steps/align_si.sh \
	--nj $training_jobs \
	--cmd run.pl \
	data/train \
	data/lang \
	exp/tri1 \
	exp/tri1_ali
fi

if [ $stage -le 11 ]; then
    mkdir -p exp/tri1/graph

    (
	utils/mkgraph.sh \
	    data/lang_test \
	    exp/tri1 \
	    exp/tri1/graph

	for fld in dev eval; do
	    steps/decode.sh \
		--nj $decoding_jobs \
		--cmd "$decode_cmd" \
		exp/tri1/graph \
		data/$fld \
		exp/tri1/decode_${fld}
	done
    ) &
fi

if [ $stage -le 12 ]; then
    echo "Starting (lda_mllt) triphone training in exp/tri2b on" `date`
    steps/train_lda_mllt.sh \
	--splice-opts "--left-context=3 --right-context=3" \
	3100 \
	50000 \
	data/train \
	data/lang \
	exp/tri1_ali \
	exp/tri2b
fi

if [ $stage -le 13 ]; then
    # align with lda and mllt adapted triphones
    steps/align_si.sh \
	--use-graphs true \
	--nj $training_jobs \
	--cmd run.pl \
	data/train \
	data/lang \
	exp/tri2b \
	exp/tri2b_ali
fi

if [ $stage -le 14 ]; then
    # Decode tri2b
    mkdir -p exp/tri2b/graph

    (
	utils/mkgraph.sh \
	    data/lang_test \
	    exp/tri2b \
	    exp/tri2b/graph

	for fld in dev eval; do
	    steps/decode.sh \
		--nj $decoding_jobs \
		--cmd "$decode_cmd" \
		exp/tri2b/graph \
		data/$fld \
		exp/tri2b/decode_${fld}
	done
    ) &
fi

if [ $stage -le 15 ]; then
        echo "Starting (SAT) triphone training in exp/tri3b on" `date`
    steps/train_sat.sh \
	--cmd run.pl \
	3100 \
	50000 \
	data/train \
	data/lang \
	exp/tri2b_ali \
	exp/tri3b
fi

if [ $stage -le 16 ]; then
    echo "Starting exp/tri3b_ali on" `date`
    steps/align_fmllr.sh \
	--nj $training_jobs \
	--cmd run.pl \
	data/train \
	data/lang \
	exp/tri3b \
	exp/tri3b_ali
fi

if [ $stage -le 17 ]; then
    # Decode tri3b
    mkdir -p exp/tri3b/graph

    (
	utils/mkgraph.sh \
	    data/lang_test \
	    exp/tri3b \
	    exp/tri3b/graph

	for fld in dev eval; do
	    steps/decode_fmllr.sh \
		--nj $decoding_jobs \
		--cmd "$decode_cmd" \
		exp/tri3b/graph \
		data/$fld \
		exp/tri3b/decode_${fld}
	done
    ) &
fi

if [ $stage -le 18 ]; then
    # train and test chain models
    local/chain/run_tdnn.sh
fi
