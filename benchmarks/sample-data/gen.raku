# Writes the shared sample data: the same records as <name>.csv and
# <name>.json, for small (100), medium (10,000) and large (100,000) records.
# Seeded with our own generator, so every run on every engine writes the same
# bytes, and every value is made up: the files contain nobody's data.
#
#   raku gen.raku                  # small, medium and large
#   raku gen.raku 1000000 huge     # huge.csv and huge.json, 1,000,000 records
#
# Both files are written by hand, not by a CSV or JSON module, so that what
# is being tested is never what produced the input.

my %sizes = small => 100, medium => 10_000, large => 100_000;
%sizes = @*ARGS[1] => @*ARGS[0].Int if @*ARGS == 2;

my @first = <Ada Grace Linus Zoë José Łukasz Søren Ngozi Ingrid Mateo
             Иван Ольга 李 美咲 Aoife Ömer Chloé Raúl Björn Priya>;
my @last  = <Lovelace Hopper Torvalds Müller García Kowalski Kierkegaard Okafor
             Bergström Rossi Петров Смирнова 王 佐藤 O'Brien Yılmaz Dubois Núñez
             Åberg Sharma>;
my @cities = (
    ('Amsterdam', 'Netherlands'), ('Bratislava', 'Slovakia'), ('Zürich', 'Switzerland'),
    ('København', 'Denmark'), ('Kraków', 'Poland'), ('Reykjavík', 'Iceland'),
    ('Москва', 'Russia'), ('東京', 'Japan'), ('São Paulo', 'Brazil'), ('Riga', 'Latvia'),
    ('Lagos', 'Nigeria'), ('Montréal', 'Canada'),
);
my @tag-words = <alpha beta gamma vip new returning wholesale eu apac trial>;
my @streets   = 'Main Street', 'Station Road', 'Lindenstraße', 'Rue de la Paix', 'Kalnciema iela',
                'Nørrebrogade', 'Тверская улица', 'Avenida Paulista';

my @columns = <id name email city country street zip lat lon amount ratio
               active manager_id tags note created>;

sub record(Int $i, &rnd) {
    my $n = $i + 1;
    my ($city, $country) = @cities[rnd(@cities.elems)];
    my $note = $n %% 7  ?? 'said "hi", then left'
            !! $n %% 11 ?? "line one\nline two"
            !! $n %% 13 ?? 'saved to C:\temp\export, tab:' ~ "\t" ~ 'end'
            !! $n %% 17 ?? "delivered 📦 on time ✓"
            !! $n %% 19 ?? ''
            !!             "plain note $n";
    my $amount = (rnd(10) == 0 ?? '-' !! '') ~ rnd(100_000) ~ '.' ~ sprintf('%02d', rnd(100));
    # every fifth ratio is an exponent form, the rest plain decimals
    my $ratio = $n %% 5 ?? "{1 + rnd(9)}.{rnd(1000)}e{rnd(2) ?? '-' !! ''}{rnd(30)}"
                        !! "0.{sprintf '%06d', rnd(1_000_000)}";
    my @tags = (^rnd(4)).map({ @tag-words[rnd(@tag-words.elems)] });
    %(
        id         => ~$n,
        name       => @first[rnd(@first.elems)] ~ ' ' ~ @last[rnd(@last.elems)],
        email      => "user$n\@example.com",
        :$city, :$country,
        street     => "{1 + rnd(250)} {@streets[rnd(@streets.elems)]}",
        zip        => sprintf('%05d', rnd(100_000)),
        lat        => sprintf('%s%d.%06d', rnd(2) ?? '-' !! '', rnd(90), rnd(1_000_000)),
        lon        => sprintf('%s%d.%06d', rnd(2) ?? '-' !! '', rnd(180), rnd(1_000_000)),
        :$amount, :$ratio,
        active     => rnd(2) ?? 'true' !! 'false',
        manager_id => $n %% 4 ?? Str !! ~(1 + rnd($n)),
        :@tags, :$note,
        created    => sprintf('20%02d-%02d-%02dT%02d:%02d:%02dZ',
                              15 + rnd(11), 1 + rnd(12), 1 + rnd(28), rnd(24), rnd(60), rnd(60)),
    )
}

sub csv-field(Str $s) {
    $s ~~ /<[",\n\r]>/ ?? '"' ~ $s.subst('"', '""', :g) ~ '"' !! $s
}

sub csv-line(%r) {
    @columns.map({
        my $v = %r{$_};
        $_ eq 'tags' ?? csv-field($v.join(','))
                     !! csv-field($v // '')
    }).join(',')
}

# JSON strings: non-ASCII as is, except in every 23rd record, where all of it
# is \u-escaped (emoji as surrogate pairs) to exercise that path too.
sub json-str(Str $s, Bool $ascii) {
    return '"' ~ $s ~ '"'
        unless $s ~~ /<["\\\x00..\x1F]>/ || ($ascii && $s ~~ /<-[\x00..\x7E]>/);
    my @out = '"';
    for $s.NFC.list -> $c {
        if    $c == 0x22 { @out.push: '\\"' }
        elsif $c == 0x5C { @out.push: '\\\\' }
        elsif $c == 0x0A { @out.push: '\\n' }
        elsif $c == 0x0D { @out.push: '\\r' }
        elsif $c == 0x09 { @out.push: '\\t' }
        elsif $c < 0x20  { @out.push: sprintf('\\u%04x', $c) }
        elsif $ascii && $c > 0xFFFF {
            my $v = $c - 0x10000;
            @out.push: sprintf('\\u%04x\\u%04x', 0xD800 + ($v +> 10), 0xDC00 + ($v +& 0x3FF));
        }
        elsif $ascii && $c > 0x7E { @out.push: sprintf('\\u%04x', $c) }
        else  { @out.push: $c.chr }
    }
    @out.push: '"';
    @out.join
}

sub json-line(%r) {
    my $a = %r<id> %% 23;
    '{' ~ join(',',
        '"id":' ~ %r<id>,
        '"name":' ~ json-str(%r<name>, $a),
        '"email":' ~ json-str(%r<email>, $a),
        '"address":{' ~ join(',',
            '"street":' ~ json-str(%r<street>, $a),
            '"zip":' ~ json-str(%r<zip>, $a),
            '"city":' ~ json-str(%r<city>, $a),
            '"country":' ~ json-str(%r<country>, $a),
            '"geo":[' ~ %r<lat> ~ ',' ~ %r<lon> ~ ']',
        ) ~ '}',
        '"amount":' ~ %r<amount>,
        '"ratio":' ~ %r<ratio>,
        '"active":' ~ %r<active>,
        '"manager_id":' ~ (%r<manager_id> // 'null'),
        '"tags":[' ~ %r<tags>.map({ json-str($_, $a) }).join(',') ~ ']',
        '"note":' ~ json-str(%r<note>, $a),
        '"created":' ~ json-str(%r<created>, $a),
        '"meta":{}',
    ) ~ '}'
}

for %sizes.sort(*.value) -> $size {
    my ($name, $count) = $size.kv;
    my $state = 2026;
    my &rnd = -> Int $n { $state = ($state * 1103515245 + 12345) % 2**31; $state % $n };

    my @csv  = @columns.join(',');
    my @json;
    for ^$count -> $i {
        my %r = record($i, &rnd);
        @csv.push:  csv-line(%r);
        @json.push: json-line(%r);
    }
    "$name.csv".IO.spurt(@csv.join("\n") ~ "\n");
    "$name.json".IO.spurt("[\n" ~ @json.join(",\n") ~ "\n]\n");
    say "$name: $count records, $name.csv {"$name.csv".IO.s} bytes, $name.json {"$name.json".IO.s} bytes";
}
