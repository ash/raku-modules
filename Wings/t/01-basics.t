use Test;
use Wings;

# Headless tests only: nothing here may open a window or touch AppKit.
# The native declarations in Wings are lazy — they dlopen on first call,
# so loading the module is safe on any OS and any thread.

plan 8;

ok True, 'module loads';

my $l = Wings::Label.new(text => 'hi', font => 13, applied => 'hi');
is $l.text, 'hi', 'Label.text readable';
$l.text = 'bye';
is $l.text, 'bye', 'Label.text writable';

my $b = Wings::Button.new(title => 'go');
isa-ok $b.clicks, Supply, 'Button.clicks is a Supply';

my $got;
$b.clicks.tap({ $got = 'clicked' });
$b.tap.emit(True);
is $got, 'clicked', 'a click emit reaches a tap';

ok !window().defined, 'window() is undefined before any app';

dies-ok { label 'orphan' },  'label outside a window block dies';
dies-ok { button 'orphan' }, 'button outside a window block dies';
