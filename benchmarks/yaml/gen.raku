#!/usr/bin/env raku
# Writes corpus.yaml: N documents in the shape of Kubernetes manifests, one
# YAML stream. Every value is computed from the document's number, so a
# corpus is reproducible byte for byte and holds nobody's data.
#
#   raku gen.raku N        # writes ./corpus.yaml
#
# Each document is a Deployment: nested block mappings, block sequences of
# mappings, flow mappings and sequences, plain, single- and double-quoted
# scalars, a folded block scalar, integers, a float, booleans and a null.
# Every tenth is a ConfigMap instead, carrying a literal block scalar, and
# anchors, aliases and a merge key.

sub MAIN(Int $n = 1000) {
    my $out = open 'corpus.yaml', :w;
    for ^$n -> $i {
        $out.print($i %% 10 ?? configmap($i) !! deployment($i));
    }
    $out.close;
}

sub name($i) { sprintf 'service-%05d', $i }

sub deployment($i) {
    my $name = name($i);
    my $port = 8000 + $i % 1000;
    my $ver  = "1.{$i % 7}.{$i % 13}";
    qq:to/YAML/;
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: $name
      namespace: team-{$i % 12}
      labels:
        app: $name
        tier: {<frontend backend worker>[$i % 3]}
        version: "$ver"
      annotations:
        description: >
          Service number $i, generated for the YAML::Native
          benchmark; it listens on port $port.
    spec:
      replicas: {1 + $i % 5}
      paused: {$i %% 17 ?? 'true' !! 'false'}
      progressDeadlineSeconds: ~
      selector:
        matchLabels:
          app: $name
      template:
        spec:
          containers:
            - name: main
              image: "registry.example.com/$name:$ver"
              ports:
                - containerPort: $port
                  protocol: TCP
              env:
                - name: LOG_LEVEL
                  value: {<info debug warn>[$i % 3]}
                - \{name: TIMEOUT, value: "{10 + $i % 50}s"}
                - name: RATIO
                  value: '0.{$i % 97}'
              resources: \{limits: \{cpu: {100 + $i % 900}m, memory: {64 * (1 + $i % 8)}Mi}}
              args: ["--port", "$port", '--verbose']
          weight: {($i % 100) / 10}e0
          tolerations: []
    YAML
}

sub configmap($i) {
    my $name = name($i);
    qq:to/YAML/;
    ---
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: {$name}-config
    data:
      defaults: &defaults
        retries: {$i % 5}
        timeout: {$i % 60}
        tls: true
      production:
        <<: *defaults
        timeout: {120 + $i % 60}
      staging: *defaults
      script: |
        #!/bin/sh
        exec /srv/$name --config /etc/$name.yaml
    YAML
}
