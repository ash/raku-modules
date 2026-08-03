use Test;
use App::Rakus;

plan 9;

is mime-for('page.html'), 'text/html; charset=utf-8', 'html carries its charset';
is mime-for('style.css'), 'text/css; charset=utf-8',  'css too';
is mime-for('logo.svg'),  'image/svg+xml',            'svg is not guessed at from text';
is mime-for('photo.png'), 'image/png',                'png is binary';
is mime-for('photo.JPEG'), 'image/jpeg',              'the extension is matched case-insensitively';

# Anything unknown is served as bytes rather than mislabelled: a browser that is
# told the wrong type does the wrong thing with the file, silently.
is mime-for('archive.tar.zst'), 'application/octet-stream', 'an unknown extension is octet-stream';
is mime-for('README'),          'application/octet-stream', 'and so is no extension at all';
is mime-for('.gitignore'),      'application/octet-stream', 'a dotfile is not an extension';
is mime-for('a.b.c.json'), 'application/json; charset=utf-8',
   'only the last extension counts';
