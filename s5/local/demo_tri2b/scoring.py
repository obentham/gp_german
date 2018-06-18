#!/usr/bin/python

arr = [line.rstrip('\n') for line in open('scoring_kaldi/wer_details/per_utt')]

ref = arr[0]
hyp = arr[1]
ref = ref[19:]
hyp = hyp[19:]

print "actual transcription: ", ref
print "hypothesis:           ", hyp
