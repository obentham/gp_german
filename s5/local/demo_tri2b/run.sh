#!/bin/bash

# runs input sound file through tri2b model and outputs text transcription

# add test.wav to directory
# put correct transcription in text
# make sure path is correct
# run ./run.sh > run.log
# output will be in output.txt

. ./path.sh

sox ./test.wav -b 16 ./test1.wav rate 16k
rm ./test.wav
mv ./test1.wav ./test.wav

./steps/make_plp_pitch.sh --nj 1 ./ ./log ./
./utils/fix_data_dir.sh .
./steps/compute_cmvn_stats.sh ./ ./log ./
./utils/fix_data_dir.sh ./

gmm-latgen-faster --max-active=7000 --beam=13.0 --lattice-beam=6.0 --acoustic-scale=0.083333 --allow-partial=true --word-symbol-table=./words.txt ./final.mdl ./HCLG.fst "ark,s,cs:apply-cmvn  --utt2spk=ark:./utt2spk scp:./cmvn.scp scp:./feats.scp ark:- | splice-feats --left-context=3 --right-context=3 ark:- ark:- | transform-feats ./final.mat ark:- ark:- |" "ark:|gzip -c > lat.1.gz"
 
./score.sh --cmd ./utils/run.pl ./ ./ ./

python ./scoring.py > output.txt

