#!/bin/bash

# takes in a file with format "ID <tab> sentence" and converts the sentence to lowercase
# the only argument  is the path to the file

cut -f 1 $1/text > $1/UID.txt
cut -f 2 $1/text > $1/sentence1.txt

cat $1/sentence1.txt | perl local/tokenizer/lowercase.perl > $1/sentence2.txt

paste $1/UID.txt $1/sentence2.txt > $1/text

rm $1/UID.txt $1/sentence1.txt $1/sentence2.txt
