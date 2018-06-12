#!/bin/bash
# -x
# Recipe to build a kaldi ASR system on the Globalphone German corpus

# source 2 files to get some environment variables
. ./cmd.sh
. ./path.sh
# The path.sh file has a  variable that points to the kaldi source code.

# initialize the stage variable
stage=0

# How do stages work?
# Use the following command to run this script starting at stage 2:
# nohup ./run.sh --stage 2 > run_stage_2.log &
# Use the <--stage n> option to start at stage n.
# Insert <exit> after stage.
# Maybe there are better ways of implementing stages?

# source a file that will handle options like --stage
. ./utils/parse_options.sh

# Set the locations of the GlobalPhone corpus and language models
gp_corpus=/mnt/corpora/Globalphone/DEU_ASR003_WAV
# This points to the directory where we have the database of speech recordings.
# You should browse that directory.
# There are recordings from 77 speakers.
# Each speaker has its own directory.
# Listen to some of the recordings.

gp_lexicon=/mnt/corpora/Globalphone/GlobalPhoneLexicons/German/German-GPDict.txt

# Set a variable that points to a URL for a standard German language model
gp_lm=http://www.csl.uni-bremen.de/GlobalPhone/lm/GE.3gram.lm.gz

#  set a variable to the directory where  data preparation will take place
tmpdir=data/local/tmp/gp/german

# The number of jobs you can run will depend on the system
decoding_jobs=5n
nj=56

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
		# The following command will get the list .wav files restricted to only the speakers in 		the current fold.
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
			# lowercase sentences in text files
			if [ "$x" == "text" ]; then
				bash local/lowercase.sh $tmpdir/$fld/lists
				bash local/ssconvert.sh $tmpdir/$fld/lists/text
				cat $tmpdir/$fld/lists/$x | sort >> data/$fld/$x
			else
				cat $tmpdir/$fld/lists/$x | sort >> data/$fld/$x
			fi
		done

		# The spk2utt file can be generated from the utt2spk file. 
		utils/utt2spk_to_spk2utt.pl data/$fld/utt2spk | sort > data/$fld/spk2utt

		utils/fix_data_dir.sh data/$fld
    done
fi

# Process the pronouncing dictionary
if [ $stage -le 1 ]; then
    mkdir -p $tmpdir/dict

    # The following  script is part of the original Globalphone kaldi recipe
    local/gp_norm_dict_GE.pl -i $gp_lexicon | sort -u > $tmpdir/dict/lexicon.txt
    
    # run lexicon through ssconvert
    bash local/ssconvert.sh $tmpdir/dict/lexicon.txt

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
	$tmpdir/lang_tmp $tmpdir/lang
fi

if [ $stage -le 3 ]; then
    # prepare the n-gram language model
    mkdir -p data/local/lm

    # get the reference lm from Bremen
    wget \
	-O data/local/lm/threegram.arpa.gz \
	$gp_lm

    # The following command creates an lm with the training  data:
    # local/prepare_lm.sh

    # Now generate the G.fst file from the lm.
    utils/format_lm.sh \
	$tmpdir/lang data/local/lm/threegram.arpa.gz data/local/dict/lexicon.txt \
	data/lang
fi

if [ $stage -le 4 ]; then
    # Create ConstArpaLm format language model
    # Notice that it ends up under data/lang_test
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
	steps/make_plp_pitch.sh data/$fld exp/make_plp_pitch/$fld plp_pitch

	utils/fix_data_dir.sh data/$fld

	steps/compute_cmvn_stats.sh data/$fld exp/make_plp_pitch/$fld plp_pitch

	utils/fix_data_dir.sh data/$fld
    done
fi

if [ $stage -le 6 ]; then
    # This is the first of several acoustic model training steps .
    # Context independent phones are trained.
    echo "Starting  monophone training in exp/mono on" `date`
    steps/train_mono.sh data/train data/lang exp/mono
fi

if [ $stage -le 7 ]; then
    # This step uses the monophones just trained to time align the data
    steps/align_si.sh data/train data/lang exp/mono exp/mono_ali
fi

if [ $stage -le 8 ]; then
    # Test the monophone models.
    (
	# A graph is required for decoding.
	utils/mkgraph.sh data/lang_test exp/mono exp/mono/graph

	for fld in dev eval; do
	    # The following command does speech recognition using the monophone models 
	    steps/decode.sh exp/mono/graph data/$fld exp/mono/decode_${fld}
	done
    ) &
    # Testing can be run in the background
fi

if [ $stage -le 9 ]; then
    # This is the first step  for training context dependent acoustic models
    echo "Starting  triphone training in exp/tri1 on" `date`
    steps/train_deltas.sh \
	--cluster-thresh 100 3100 50000 data/train data/lang exp/mono_ali \
	exp/tri1
fi

if [ $stage -le 10 ]; then
    # align with triphones
    steps/align_si.sh data/train data/lang exp/tri1 exp/tri1_ali
fi

if [ $stage -le 11 ]; then
    # Test the triphone models.
    (
	utils/mkgraph.sh data/lang_test exp/tri1 exp/tri1/graph

	for fld in dev eval; do
	    steps/decode.sh exp/tri1/graph data/$fld exp/tri1/decode_${fld}
	done
    ) &
fi

if [ $stage -le 12 ]; then
    # Trains with front end feature adaptation.
    echo "Starting (lda_mllt) triphone training in exp/tri2b on" `date`
    steps/train_lda_mllt.sh \
	--splice-opts "--left-context=3 --right-context=3" \
	3100 50000 data/train data/lang exp/tri1_ali exp/tri2b
fi

if [ $stage -le 13 ]; then
    # align with lda and mllt adapted triphones
    steps/align_si.sh \
	--use-graphs true data/train data/lang exp/tri2b exp/tri2b_ali
fi

if [ $stage -le 14 ]; then
    # Decode tri2b
    (
	utils/mkgraph.sh data/lang_test exp/tri2b exp/tri2b/graph

	for fld in dev eval; do
	    steps/decode.sh exp/tri2b/graph data/$fld exp/tri2b/decode_${fld}
	done
    ) &
fi

if [ $stage -le 15 ]; then
    # Models are speaker adapted.
        echo "Starting (SAT) triphone training in exp/tri3b on" `date`
    steps/train_sat.sh 3100 50000 data/train data/lang exp/tri2b_ali exp/tri3b
fi

if [ $stage -le 16 ]; then
    echo "Starting exp/tri3b_ali on" `date`
    steps/align_fmllr.sh data/train data/lang exp/tri3b exp/tri3b_ali
fi

if [ $stage -le 17 ]; then
    # Decode tri3b
    (
	utils/mkgraph.sh data/lang_test exp/tri3b exp/tri3b/graph

	for fld in dev eval; do
	    steps/decode_fmllr.sh \
		exp/tri3b/graph data/$fld exp/tri3b/decode_${fld}
	done
    ) &
fi

if [ $stage -le 18 ]; then
    # train and test chain models
    local/chain/run_tdnn.sh
fi
