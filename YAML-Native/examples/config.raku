# Read a configuration document — anchors, a merge key, block scalars — and
# use its values as the Raku types they arrive as; then read a stream of
# several documents, and show which implementation answered.
#
#   raku   -Ilib examples/config.raku
#   rakupp -Ilib examples/config.raku

use YAML::Native;

my %conf = from-yaml(q:to/YAML/);
    # a CI configuration, of the kind merge keys were made for
    defaults: &defaults
      image: rakudo-star:latest
      retries: 2
      timeout: 30.5
      cache: ~

    jobs:
      test:
        <<: *defaults
        script: |
          zef install --deps-only .
          prove6 -l t
      release:
        <<: *defaults
        retries: 0
        only: [main, "v*"]
        notes: >
          Runs on the main branch
          and on version tags.
    YAML

say "parsed by the {yaml-backend()} backend";
say %conf<jobs><test><image>;                          # rakudo-star:latest — merged in
say %conf<jobs><release><retries>;                     # 0 — its own key wins
say %conf<jobs><test><timeout> * 2;                    # 61 — a Num
say %conf<jobs><test><cache>.defined;                  # False — ~ is null
say %conf<jobs><release><only>.join(' | ');            # main | v*
print %conf<jobs><test><script>;                       # two lines, as written
print %conf<jobs><release><notes>;                     # one line, folded

# A stream of documents, as Kubernetes writes them.
my @docs = from-yaml(q:to/YAML/, :all);
    kind: Service
    metadata: {name: web}
    ---
    kind: Deployment
    metadata: {name: web}
    spec: {replicas: 3}
    YAML
say @docs.map({ "{.<kind>}/{.<metadata><name>}" }).join(', ');   # Service/web, Deployment/web

# Errors name the line.
try from-yaml("a: 1\nb: 2\na: 3\n");
say $!.message;                                        # YAML::Native: duplicate key 'a' at line 3
