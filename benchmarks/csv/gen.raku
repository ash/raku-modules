# The CSV::Native benchmark corpus — synthetic and deterministic (no
# randomness: every value is a function of the row number), with the shapes
# real files have: plain fields, quoted ones with separators and doubled
# quotes, a multi-line field now and then, non-ASCII.
my $n = @*ARGS[0] // 100_000;          # rows; the file is written to corpus.csv in the current directory
my @out = 'id,name,email,city,amount,note,tags,active';
my @cities = <Amsterdam Bratislava Zürich København Москва 東京 Paris Lima>;
for ^$n -> $i {
    my $note = $i %% 7  ?? "\"said \"\"hi\"\", then left\""
             !! $i %% 11 ?? "\"line one\nline two\""
             !!             "plain note $i";
    my $tags = $i %% 3 ?? "\"a,b,c\"" !! "solo";
    @out.push("$i,User $i,user$i\@example.com,@cities[$i % 8],{($i * 37) % 10000}.{$i % 100},$note,$tags,{$i %% 2 ?? 'true' !! 'false'}");
}
"corpus.csv".IO.spurt(@out.join("\n") ~ "\n");
say "corpus.csv: {'corpus.csv'.IO.s} bytes, $n records";
