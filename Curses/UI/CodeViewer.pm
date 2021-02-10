#
# This file is part of Asmex.
#
# Asmex is free software: you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# Asmex is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
# details.
#
# You should have received a copy of the GNU General Public License along with
# Asmex. If not, see <https://www.gnu.org/licenses/>.
#

package Curses::UI::CodeViewer;

use Curses;
use Curses::UI::Widget;
use Curses::UI::Common;

use vars qw(@ISA);
use constant {
    LINE_PREFIX => 0,
    LINE_TEXT   => 1,
    LINE_ATTRS  => 2,

    ATTR_FG     => 0,
    ATTR_BG     => 1,
    ATTR_BOLD   => 2
};

@ISA = qw(Curses::UI::Widget Curses::UI::Common);


my %routines = (
    'lose-focus'     => \&loose_focus,
    'transmit-event' => \&transmit_event,
    'navig'          => \&navig,
    'go-up'          => \&go_up,
    'go-down'        => \&go_down,
    'go-pageup'      => \&go_pageup,
    'go-pagedown'    => \&go_pagedown,
    'go-left'        => \&go_left,
    'go-right'       => \&go_right,
    'query-fwd'      => \&query_forward,
    'query-bwd'      => \&query_backward,
    'update-query'   => \&update_query,
    'backspc-query'  => \&backspc_query,
    'delete-query'   => \&delete_query,
    'search'         => \&search,
    'search-prev'    => \&search_prev,
    'search-next'    => \&search_next
    );

my %common_bindings = (
    CUI_TAB()    => 'lose-focus',
    KEY_BTAB()   => 'lose-focus',
    );

my %navig_bindings = (
    KEY_UP()     => 'go-up',
    KEY_DOWN()   => 'go-down',
    KEY_PPAGE()  => 'go-pageup',
    KEY_NPAGE()  => 'go-pagedown',
    '?'          => 'query-bwd',
    '/'          => 'query-fwd',
    ''           => 'transmit-event'
    );

my %query_bindings = (
    KEY_LEFT()      => 'go-left',
    KEY_RIGHT()     => 'go-right',
    KEY_ENTER()     => 'search',
    KEY_BACKSPACE() => 'backspc-query',
    KEY_DC()        => 'delete-query',
    ''              => 'update-query'
    );

my %search_bindings = (
    'N' => 'search-prev',
    'n' => 'search-next',
    '?' => 'query-bwd',
    '/' => 'query-fwd',
    ''  => 'navig'
    );


sub new()
{
    my $class = shift();
    my %args = (
	-ypos                => 0,              # number of top line
	-ycur                => 0,              # number of cursor line
	-prwidth             => 0,              # prefix min width
	-onkey               => sub {},
	-oncursor            => sub {},

	@_,

	-lines               => [],
	-prlwidth            => 0,              # actual prefix width

	-mode                => 'navig',
	-query               => '',
	-querydir            => '',             # fwd or bwd
	-qcur                => 0,              # position of query cursor

	-bindings            => {},
	-routines            => { %routines },
	);
    my $this = $class->SUPER::new( %args );

    $this->set_mode($this->{-mode});
    $this->layout();

    return $this;
}


# Public interface ============================================================

sub mode
{
    my ($self) = @_;

    return $self->{-mode};
}

# Structure of lines:
# LINES = [ [ PREFIX , TEXT , ATTRS ] ]
#   PREFIX is an optional text
#   TEXT   is the line text
#   ATTRS = [ FG or undef
#           , BG or undef
#           , BOLD (bool)
#           ]

sub lines
{
    my ($self, $lines) = @_;
    my ($line, $prlwidth, $prefix, $len);

    if (defined($lines)) {
	$prlwidth = $self->{-prwidth};

	foreach $line (@$lines) {
	    $prefix = $line->[LINE_PREFIX];

	    if (!defined($prefix)) {
		next;
	    }

	    $len = length($prefix);
	    if ($len > $prlwidth) {
		$prlwidth = $len;
	    }
	}

	$self->{-lines} = $lines;
	$self->{-prlwidth} = $prlwidth;
    }

    return $self->{-lines};
}

sub cursor
{
    my ($self, $value) = @_;
    my ($lines, $ypos, $height);

    if (defined($value)) {
	$lines = $self->{-lines};

	if ($value < 0) {
	    $value = 0;
	} elsif ($value >= scalar(@$lines)) {
	    $value = scalar(@$lines) - 1;
	}

	$ypos = $self->{-ypos};
	$height = $self->canvasheight();

	if ($value < $ypos) {
	    $ypos = $value - int($height / 5);
	} elsif ($value >= ($ypos + $height)) {
	    $ypos = $value - $height + 1 + int($height / 5);
	}

	if ($ypos >= (scalar(@$lines) - $height)) {
	    $ypos = scalar(@$lines) - $height;
	}

	if ($ypos < 0) {
	    $ypos = 0;
	} 

	$self->{-ypos} = $ypos;
	$self->{-ycur} = $value;

	$self->draw(1);

	$self->cursor_event();
    }

    return $self->{-ycur};
}

sub onkey
{
    my ($self, $handler) = @_;

    if (defined($handler)) {
	$self->{-onkey} = $handler;
    }

    return $self->{-onkey};
}

sub oncursor
{
    my ($self, $handler) = @_;

    if (defined($handler)) {
	$self->{-oncursor} = $handler;
    }

    return $self->{-oncursor};
}


# Private =====================================================================

sub set_mode(;$)
{
    my ($this, $mode) = @_;

    if ($mode eq 'navig') {
	$this->{-bindings} = { %common_bindings, %navig_bindings };
    } elsif ($mode eq 'query') {
	$this->{-bindings} = { %common_bindings, %query_bindings };
    } elsif ($mode eq 'search') {
	$this->{-bindings} = { %common_bindings, %search_bindings };
    } else {
	return $this;
    }

    $this->{-mode} = $mode;

    return $this;
}

sub cursor_event
{
    my ($self) = @_;

    $self->{-oncursor}->($self);
}

sub transmit_event
{
    my ($self, $key) = @_;

    $self->{-onkey}->($self, $key);
}

sub layout()
{
    my $this = shift();

    $this->SUPER::layout();

    if ($Curses::UI::screen_too_small) {
	return $this;
    }

    return $this;
}

sub draw(;$)
{
    my $this = shift();
    my $no_doupdate = shift() || 0;

    if ($this->hidden()) {
	return $this;
    }

    $this->SUPER::draw(1);

    $this->draw_text();

    if ($this->{-mode} eq 'query') {
	$this->draw_query();
    }

    $this->{-canvasscr}->noutrefresh();

    if (!$no_doupdate) {
	doupdate();
    }

    return $this;
}

sub draw_line(;$$$)
{
    my ($this, $y, $ycur, $text) = @_;
    my ($query, $before, $match, $after, $num);

    if ($y == $ycur) {
	$this->{-canvasscr}->attron(A_REVERSE);
    }

    if ($this->{-mode} eq 'search') {
	$query = $this->{-query};
	$query = qr/$query/;
	$num = 0;

	while ($text =~ /^(.*?)($query)(.*)$/) {
	    ($before, $match, $after) = ($1, $2, $3);

	    $this->{-canvasscr}->addstr($y, $num, $before);
	    $num += length($before);

	    if ($y == $ycur) {
		$this->{-canvasscr}->attroff(A_REVERSE);
	    } else {
		$this->{-canvasscr}->attron(A_REVERSE);
	    }

	    $this->{-canvasscr}->addstr($y, $num, $match);
	    $num += length($match);

	    if ($y == $ycur) {
		$this->{-canvasscr}->attron(A_REVERSE);
	    } else {
		$this->{-canvasscr}->attroff(A_REVERSE);
	    }

	    $text = $after;

	    if ($text eq '') {
		last;
	    }
	}

	$this->{-canvasscr}->addstr($y, $num, $text);
    } else {
	$this->{-canvasscr}->addstr($y, 0, $text);
    }

    if ($y == $ycur) {
	$this->{-canvasscr}->attroff(A_REVERSE);
    }

    return $this;
}

sub draw_text(;)
{
    my $this = shift();
    my ($width, $height, $lines, $ypos, $ycur, $co, $query);
    my ($y, $line, $prefix, $text, $attrs, $fg, $bg, $color);
    my ($prlwidth, $template);

    $height = $this->canvasheight();
    $lines = $this->{-lines};
    $ypos = $this->{-ypos};

    if ($height >= scalar(@$lines)) {
	$ypos = 0;
    } elsif ($ypos >= (scalar(@$lines) - $height)) {
	$ypos = scalar(@$lines) - $height;
    } elsif ($ypos < 0) {
	$ypos = 0;
    }

    $ycur = $this->{-ycur} - $ypos;

    if ($ycur < 0) {
	$ycur = 0;
    } elsif ($ycur >= $height) {
	$ycur = $height - 1;
    }

    $prlwidth = $this->{-prlwidth};
    $width = $this->canvaswidth();

    if ($prlwidth > 0) {
	$template = sprintf("%%%ds %%-%ds", $prlwidth, $width - $prlwidth - 1);
    } else {
	$template = sprintf("%%-%ds", $width);
    }

    $co = $Curses::UI::color_object;
    $query = $this->{-query};

    for ($y = 0; $y < $height; $y++) {
	$line = $lines->[$y + $ypos];

	$prefix = $line->[LINE_PREFIX];
	$text = $line->[LINE_TEXT];
	$attrs = $line->[LINE_ATTRS];

	if ($prlwidth > 0) {
	    if (!defined($prefix)) {
		$prefix = '';
	    }
	    $text = sprintf($template, $prefix, $text);
	} else {
	    $text = sprintf($template, $text);
	}

	if (defined($attrs)) {
	    if (defined($attrs->[ATTR_FG]) || defined($attrs->[ATTR_BG])) {
		$fg = $attrs->[ATTR_FG] || 'white';
		$bg = $attrs->[ATTR_BG] || 'black';
		$color = COLOR_PAIR($co->get_color_pair($fg, $bg));
		$this->{-canvasscr}->attron($color);
	    } else {
		$color = undef;
	    }

	    if ($attrs->[ATTR_BOLD]) {
		$this->{-canvasscr}->attron(A_BOLD);
	    }
	}

	$this->draw_line($y, $ycur, $text);

	if (defined($color)) {
	    $this->{-canvasscr}->attroff($color);
	}

	$this->{-canvasscr}->attroff(A_BOLD);
    }

    return $this;
}

sub draw_query(;)
{
    my ($this) = @_;
    my ($height, $width, $y, $text);

    $width = $this->canvaswidth();
    $height = $this->canvasheight();
    $y = $height - 1;

    $text = sprintf("/%%-%ds", $width - 1);
    $text = sprintf($text, $this->{-query});
    $this->{-canvasscr}->addstr($y, 0, $text);

    $this->{-canvasscr}->move($y, $this->{-qcur} + 1);

    return $this;
}

sub navig(;)
{
    my ($this) = @_;

    $this->set_mode('navig');
    $this->draw(1);

    return $this;
}

sub move
{
    my ($this, $amount) = @_;
    my ($ycur, $height, $lines);

    $ycur = $this->{-ycur} + $amount;
    $lines = $this->{-lines};

    if ($ycur < 0) {
	$ycur = 0;
    } elsif ($ycur >= scalar(@$lines)) {
	$ycur = scalar(@$lines) - 1;
    }

    $ypos = $this->{-ypos};

    if ($ycur < $ypos) {
	$ypos = $ycur;
    } else {
        $height = $this->canvasheight();

	if ($ycur >= ($ypos + $height)) {
	    $ypos = $ycur - $height + 1;
	}
    }

    $this->{-ypos} = $ypos;
    $this->{-ycur} = $ycur;
    $this->draw(1);

    $this->cursor_event();

    return $this;
}

sub move_cursor
{
    my ($self, $amount) = @_;
    my ($cursor);

    $cursor = $self->cursor();
    $self->cursor($cursor + $amount);

    return $self;
}

sub go_up(;)
{
    my ($this) = @_;

    return $this->move_cursor(-1);
}

sub go_down(;)
{
    my ($this) = @_;

    return $this->move_cursor(1);
}

sub go_pageup(;)
{
    my ($this) = @_;

    return $this->move_cursor(- $this->canvasheight());
}

sub go_pagedown(;)
{
    my ($this) = @_;

    return $this->move_cursor($this->canvasheight());
}

sub go_left(;)
{
    my ($this) = @_;

    if ($this->{-qcur} > 0) {
	$this->{-qcur} -= 1;
    }
    $this->draw(1);

    return $this;
}

sub go_right(;)
{
    my ($this) = @_;

    if ($this->{-qcur} < length($this->{-query})) {
	$this->{-qcur} += 1;
    }
    $this->draw(1);

    return $this;
}

sub update_query(;$)
{
    my ($this, $key) = @_;

    $this->{-query} .= $key;
    $this->{-qcur} += 1;
    $this->draw(1);

    return $this;
}

sub backspc_query(;)
{
    my ($this) = @_;
    my ($pos, $query);

    $pos = $this->{-qcur};
    if ($pos == 0) {
	return $this;
    }

    $query = $this->{-query};
    $query = substr($query, 0, $pos - 1) . substr($query, $pos);
    $pos -= 1;

    $this->{-qcur} = $pos;
    $this->{-query} = $query;

    $this->draw(1);

    return $this;
}

sub delete_query(;)
{
    my ($this) = @_;
    my ($pos, $query);

    $pos = $this->{-qcur};
    $query = $this->{-query};

    if ($pos == length($query)) {
	return $this;
    }

    $this->{-query} = substr($query, 0, $pos) . substr($query, $pos + 1);

    $this->draw(1);

    return $this;
}

sub query_forward(;)
{
    my ($this) = @_;

    $this->set_mode('query');
    $this->{-query} = '';
    $this->{-querydir} = 'fwd';
    $this->{-qcur} = 0;
    $this->draw(1);

    return $this;
}

sub query_backward(;)
{
    my ($this) = @_;

    $this->set_mode('query');
    $this->{-query} = '';
    $this->{-querydir} = 'bwd';
    $this->{-qcur} = 0;
    $this->draw(1);

    return $this;
}

sub search(;)
{
    my ($this) = @_;

    $this->set_mode('search');

    if ($this->{-querydir} eq 'fwd') {
	$this->search_next();
    } else {
	$this->search_prev();
    }

    return $this;
}

sub search_prev(;)
{
    my ($this) = @_;
    my ($query, $pos, $y, $lines, $line, $text);

    $query = $this->{-query};
    $pos = $this->{-ycur};
    $lines = $this->{-lines};

    for ($y = $pos - 1; $y >= 0; $y--) {
	$line = $lines->[$y];
	$text = $line->[LINE_TEXT];

	if (!($text =~ /$query/)) {
	    next;
	}

	$this->cursor($y);

	last;
    }

    return $this;
}

sub search_next(;)
{
    my ($this) = @_;
    my ($query, $pos, $y, $lines, $line, $text);

    $query = $this->{-query};
    $pos = $this->{-ycur};
    $lines = $this->{-lines};

    for ($y = $pos + 1; $y < scalar(@$lines); $y++) {
	$line = $lines->[$y];
	$text = $line->[LINE_TEXT];

	if (!($text =~ /$query/)) {
	    next;
	}

	$this->cursor($y);

	last;
    }

    return $this;
}

sub focus()
{
    my $this = shift();

    $this->show();

    return $this->generic_focus(
	undef,
	NO_CONTROLKEYS,
	CURSOR_VISIBLE,
	);
}


1;
__END__
