#!/bin/bash -u
. ./cmd.sh
. ./path.sh

stage=0

. ./utils/parse_options.sh

# Set the locations of the GlobalPhone corpus and language models
gp_corpus=/mnt/corpora/Globalphone/DEU_ASR003_WAV
gp_lexicon=/mnt/corpora/Globalphone/GlobalPhoneLexicons/German/German-GPDict.txt
gp_lm=http://www.csl.uni-bremen.de/GlobalPhone/lm/GE.3gram.lm.gz

tmpdir=data/local/tmp/gp/german
decoding_jobs=5
training_jobs=56
# global phone d
ata prep
if [ $stage -le 0 ]; then

    mkdir -p $tmpdir/lists

    # get list of globalphone .wav files
    find \
	$gp_corpus/adc \
	-type f \
	-name "*.wav" \
	| \
	sort \
	    > \
	    $tmpdir/lists/wav.txt

    find \
	$gp_corpus/trl \
	-type f \
	-name "*.trl" \
	| \
	sort \
	> \
	$tmpdir/lists/trl.txt

    for fld in dev eval train; do
	mkdir -p $tmpdir/$fld/lists

	grep \
	    -f conf/${fld}_spk.list  \
	    $tmpdir/lists/wav.txt  \
	    > \
	    $tmpdir/$fld/lists/wav.txt

	grep \
	    -f conf/${fld}_spk.list  \
	    $tmpdir/lists/trl.txt  \
	    > \
	    $tmpdir/$fld/lists/trl.txt

	local/get_prompts.pl $fld

	# make training lists
	local/make_lists.pl $fld

	utils/fix_data_dir.sh \
	    $tmpdir/$fld/lists

	# consolidate  data lists
	mkdir -p data/$fld
	for x in wav.scp text utt2spk; do
	    cat \
		$tmpdir/$fld/lists/$x \
		| \
		sort \
		    >> \
		    data/$fld/$x
	done

	utils/utt2spk_to_spk2utt.pl \
	    data/$fld/utt2spk \
	    | \
	    sort \
		> \
		data/$fld/spk2utt

	utils/fix_data_dir.sh \
	    data/$fld
    done
fi

if [ $stage -le 1 ]; then
    mkdir -p $tmpdir/dict

    local/gp_norm_dict_GE.pl \
	-i $gp_lexicon \
	| \
	sort -u \
	     > \
	     $tmpdir/dict/lexicon.txt || exit 1;

    local/prepare_dict.sh
fi

if [ $stage -le 2 ]; then
    # prepare lang directory
    utils/prepare_lang.sh \
	--position-dependent-phones true \
	data/local/dict \
	"<UNK>" \
	data/local/lang_tmp \
	data/lang || exit 1;
fi

if [ $stage -le 3 ]; then
    # prepare the lm
    mkdir -p data/local/lm

        # get the reference lm from Bremen
    wget \
	-O data/local/lm/threegram.arpa.gz \
	$gp_lm

    #local/prepare_lm.sh

    utils/format_lm.sh \
	data/lang \
	data/local/lm/threegram.arpa.gz \
	data/local/dict/lexicon.txt \
	data/lang_test
fi

if [ $stage -le 4 ]; then
    # Create ConstArpaLm format language model for full 3-gram and 4-gram LMs
    utils/build_const_arpa_lm.sh \
	data/local/lm/threegram.arpa.gz \
	data/lang \
	data/lang_test
fi

if [ $stage -le 5 ]; then
    # extract acoustic features
    mkdir -p exp

    if [ -e data/train/cmvn.scp ]; then
	rm data/train/cmvn.scp
    fi

    for fld in dev eval train ; do
	steps/make_plp_pitch.sh \
	    --cmd run.pl \
	    --nj $training_jobs \
	    data/$fld \
	    exp/make_plp_pitch/$fld \
	    plp_pitch || exit 1;

	utils/fix_data_dir.sh \
	    data/$fld || exit 1;

	steps/compute_cmvn_stats.sh \
	    data/$fld \
	    exp/make_plp_pitch/$fld \
	    plp_pitch || exit 1;

	utils/fix_data_dir.sh \
	    data/$fld || exit 1;
    done
fi

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
