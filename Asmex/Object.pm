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

package Asmex::Object;

use strict;
use warnings;

use base qw(Exporter);

use constant {
    CODE_ADDR => 0,
    CODE_BIN  => 1,
    CODE_ASM  => 2,

    SUBPROG_NAME   => 0,
    SUBPROG_LNAME  => 1,
    SUBPROG_FINDEX => 2,
    SUBPROG_LNUM   => 3,
    SUBPROG_ORIG   => 4,

    DLINE_FILE   => 0,
    DLINE_LNUM   => 1,
    DLINE_COLUMN => 2,
    DLINE_STMT   => 3,
    DLINE_DISCR  => 4,
    };


our @EXPORT = (
    'CODE_ADDR', 'CODE_BIN', 'CODE_ASM',
    'DLINE_FILE', 'DLINE_LNUM', 'DLINE_COLUMN', 'DLINE_STMT', 'DLINE_DISCR'
    );


sub new
{
    my ($class, $path, %opts) = @_;
    my $self = bless({}, $class);
    my $value;

    if (defined($value = $opts{DEBUG})) {
	if (ref($value) eq 'GLOB') {
	    $self->{_debug} = $value;
	} else {
	    return undef;
	}
	$self->{_debug_indent} = 0;
    }

    return $self->_parse($path)
}


sub _debug
{
    my ($self, $msg) = @_;
    my ($fh, $indent);

    $fh = $self->{_debug};
    $indent = $self->{_debug_indent};

    if (!defined($fh)) {
	return;
    }

    printf($fh "[%s] %s%s\n", __PACKAGE__, '  ' x $indent, $msg);
}

sub _debug_enter
{
    my ($self) = @_;
    my ($indent);

    $indent = $self->{_debug_indent};

    if (defined($indent)) {
	$self->{_debug_indent} += 1;
    }
}

sub _debug_exit
{
    my ($self) = @_;
    my ($indent);

    $indent = $self->{_debug_indent};

    if (defined($indent)) {
	$self->{_debug_indent} -= 1;
    }
}


# Parse the file with the given $path (assumed to include DWARF information)
# and extract the debug data.
#
sub _parse
{
    my ($self, $path) = @_;
    my $ret;

    $self->_debug("Parse '$path'");
    $self->_debug_enter();

    $ret = $self->_parse_code($path);
    if (!defined($ret)) {
	return undef;
    }

    $ret = $self->_parse_compdir($path);
    if (!defined($ret)) {
	return undef;
    }

    $ret = $self->_parse_symbols($path);
    if (!defined($ret)) {
	return undef;
    }

    $ret = $self->_parse_info($path);
    if (!defined($ret)) {
	return undef;
    }

    $ret = $self->_parse_lines($path);
    if (!defined($ret)) {
	return undef;
    }

    $self->_match_sections();

    $self->_debug_exit();
    return $self;
}

# Parse the assembly code from the given $path.
# Fills two fields of $self:
#
# $self->{_sections} = [ STRING ]
#   The list of the ELF sections in the order they appear in the result of
#   `objdump -d`.
#
# $self->{_code} = {
#     STRING(1) => {
#         STRING(2) => [ [ INT(3) , STRING(4) , STRING(5) ] ... ]
#     }
# }
#   A multi-level table which gives for a given section name(1) and an entry
#   name (2) a list of assembly instructions in the order they appear with for
#   each instruction the address(3), the binary instruction(4) and the human
#   readable assembly(5).
#
# Return $self on success, undef otherwise.
#
sub _parse_code
{
    my ($self, $path) = @_;
    my ($fh, $line, $section, $entry, $addr, $bin, $asm, $type, $symbol);
    my (@sections, $code);
    my @command = ('objdump', '-dCr', $path);

    $self->_debug("Parse code: " . join(' ', map { "'$_'" } @command));
    $self->_debug_enter();

    if (!open($fh, '-|', @command)) {
	$self->_debug_exit();
	return undef;
    }

    while (defined($line = <$fh>)) {
	chomp($line);

	if ($line =~ m|^\s*([0-9a-f]+):\s+([0-9a-f]{2}(?: [0-9a-f]{2})*)(?:\s+(.*\S))?\s*$|) {
	    ($addr, $bin, $asm) = ($1, $2, $3);
	    $addr = hex('0x' . $addr);

	    $self->_debug(sprintf("Code [%s] [%s] += %8x: %-16s %s",
			  $section, $entry, $addr, $bin, $asm));

	    push(@{$code->{$section}->{$entry}}, [ $addr, $bin, $asm ]);

	    next;
	}

	if ($line =~ m|^\s*([0-9[a-f]+):\s+(R_.*\S)\s+(.*\S)\s*$|) {
	    ($addr, $type, $symbol) = ($1, $2, $3);
	    $symbol =~ s|-0x[0-9a-f]+$||;
	    $code->{$section}->{$entry}->[-1]->[CODE_ASM]
		=~ s|<.*>\s*$|<$symbol>|;
	    next;
	}

	if ($line =~ m|^([0-9a-f]+) <(.*)>:\s*$|) {
	    ($addr, $entry) = ($1, $2);
	    next;
	}

	if ($line =~ m|^\s*$|) {
	    next;
	}

	if ($line =~ m|^Disassembly of section (.*):\s*$|) {
	    $section = $1;
	    push(@sections, $section);
	    next;
	}

	if ($line =~ m|^(.*):\s+file format (.*\S)\s*$|) {
	    # ($file, $format) = ($1, $2);
	    next;
	}

	$self->_debug("Unknown line : '$line'");
	printf(STDERR "Unknown line: %s\n", $line);
    }

    close($fh);

    $self->{_sections} = \@sections;
    $self->{_code} = $code;

    $self->_debug_exit();
    return $self;
}

# Parse the compilation directory from the given $path.
# Fills the field $self->{_compdir} with the absolute path of the compilation
# directory of the ELF with the given $path.
#
# Return $self on success, undef otherwise.
#
sub _parse_compdir
{
    my ($self, $path) = @_;
    my ($fh, $line, $dir);
    my @command = ('objdump', '--dwarf=info', $path);

    if (!open($fh, '-|', @command)) {
	return undef;
    }

    while (defined($line = <$fh>)) {
	chomp($line);

	if ($line =~ m|DW_AT_comp_dir.*: (/.*)$|) {
	    $dir = $1;
	    last;
	}
    }

    close($fh);

    $self->{_compdir} = $dir;

    return $self;
}

# Parse the symbol table from the given $path.
# Fills the following field of $self:
#
# $self->{_symbols} = {
#     STRING(1) => {
#         INT(2) => [ [ STRING(3), INT(4) ] ... ]
#     }
# }
#   A multi-level table which gives for a given section name(1) and an
#   address(2) in this section a list of associated symbol names(3) and the
#   address they end(4).
#
# Return $self on success, undef otherwise.
#
sub _parse_symbols
{
    my ($self, $path) = @_;
    my ($table, $fh, $line, $addr, $section, $size, $end, $symbol);
    my @command = ('objdump', '--syms', $path);

    if (!open($fh, '-|', @command)) {
	return undef;
    }

    while (defined($line = <$fh>)) {
	chomp($line);

	if ($line =~ m|^([0-9a-f]+) .{7} (\S+)\s+([0-9a-f]+)\s+(.*)$|) {
	    ($addr, $section, $size, $symbol) = ($1, $2, $3, $4);
	    $addr = hex('0x' . $addr);
	    $end = $addr + hex('0x' . $size);
	    push(@{$table->{$section}->{$addr}}, [ $symbol, $end ]);
	    next;
	}

	if ($line eq '') {
	    next;
	}

	if ($line eq 'SYMBOL TABLE:') {
	    next;
	}

	if ($line =~ m|^.*\S:\s+file format .*$|) {
	    next;
	}

	printf(STDERR "Unknown line: %s\n", $line);
    }

    close($fh);

    $self->{_symbols} = $table;

    return $self;
}

# Parse the debug info from the given $path.
# Fills the following field of $self:
#
# $self->{_info} = { STRING(1) => [ INT(2), INT(3) ] }
#   A table which gives for a given entry name(1) (see `_parse_code()`) the
#   file index(2) (see `_update_info()`) and the line number(3) of the source
#   file defining the corresponding function.
#
# Note: The DWARF info has two ways to record that: a direct or an indirect
#       subprogram entry. Both are identified by a `DW_TAG_subprogram` tag.
#       The direct one has a `DW_AT_decl_file` and a `DW_AT_decl_line` tag
#       while the indirect has a `DW_AT_abstract_origin` tag which indicates
#       a direct entry from which to take the information.
#
# Return $self on success, undef otherwise.
#
sub _parse_info
{
    my ($self, $path) = @_;
    my ($table, $fh, $line, $tag, $subprogs, $id);
    my ($name, $lname, $findex, $ln, $orig);
    my @command = ('objdump', '--dwarf=info', $path);

    if (!open($fh, '-|', @command)) {
	return undef;
    }

    $tag = '';

    while (defined($line = <$fh>)) {
	chomp($line);

	if ($line =~ m|<([0-9a-f]+)>:\s*.*\(DW_TAG_(.*)\)$|) {
	    if (defined($id)) {
		$subprogs->{$id} = [ $name, $lname, $findex, $ln, $orig ];
	    }

	    ($id, $tag) = ($1, $2);
	    $name = undef;
	    $lname = undef;
	    $findex = undef;
	    $ln = undef;
	    $orig = undef;

	    next;
	}

	if ($tag ne 'subprogram') {
	    next;
	}

	if ($line =~ m|DW_AT(_linkage)?_name\s*:(?:\s*\(indirect string.*?\):)?\s+(.*)$|){
	    if (defined($1)) {
		$lname = $2;
	    } else {
		$name = $2;
	    }
	    next;
	}

	if ($line =~ m|DW_AT_abstract_origin\s*:\s+<0x([0-9a-f]+)>$|) {
	    $orig = $1;
	    next;
	}

	if ($line =~ m|DW_AT_decl_file\s*:\s+(\d+)$|) {
	    $findex = $1;
	    next;
	}

    	if ($line =~ m|DW_AT_decl_line\s*:\s+(\d+)$|) {
	    $ln = $1;
	    next;
	}
    }

    if (defined($id)) {
	$subprogs->{$id} = [ $name, $lname, $findex, $ln, $orig ];
    }

    foreach $id (keys(%$subprogs)) {
	$name = $subprogs->{$id}->[SUBPROG_LNAME];

	if (!defined($name)) {
	    $name = $subprogs->{$id}->[SUBPROG_NAME];
	}

	if (!defined($name)) {
	    next;
	}

	$findex = $subprogs->{$id}->[SUBPROG_FINDEX];
	$ln = $subprogs->{$id}->[SUBPROG_LNUM];

	if (defined($findex) && defined($ln)) {
	    $table->{$name} = [ $findex, $ln ];
	    next;
	}

	$orig = $subprogs->{$id}->[SUBPROG_ORIG];

	if (!defined($orig)) {
	    next;
	}

	$findex = $subprogs->{$orig}->[SUBPROG_FINDEX];
	$ln = $subprogs->{$orig}->[SUBPROG_LNUM];

	if (defined($findex) && defined($ln)) {
	    $table->{$name} = [ $findex, $ln ];
	    next;
	}
    }

    close($fh);

    $self->{_info} = $table;

    return $self;
}

# Parse the debug line from the given $path.
# Fills the following field of $self:
#
# $self->{_lines} = [
#     { INT(1) => [ [ STRING(2), INT(3), INT(4), BOOL(5), INT(6) ] ... ] }
#     ...
# ]
#   A list of debug sequence, each of them begin a table which gives for an
#   address(1) the path(2) of the corresponding source file as well as the
#   line(3) and column(4) numbers and if the source is the beginning of a
#   statement(5) and the discriminator number(6).
#
# Also resolve the file indices (see `_parse_info()` and `_update_info()`).
#
# Note: For more information about the discriminator number, see the official
#       DWARF documentation.
#
# Note: There is no easy way I know to link a debug sequence to an ELF section.
#       As a result, many sequences may indicate different debug information
#       for the same address.
#       All the complexity of `_match_sections()` comes from this missing
#       information.
#
# Return $self on success, undef otherwise.
#
sub _parse_lines
{
    my ($self, $path) = @_;
    my ($dtable, $ftable, $fh, $line, $dindex, $findex, $dir, $file, $inst);
    my ($table, $sequence, $addr, $dfile, $ln, $column, $stmt, $discr);
    my @command = ('objdump', '--dwarf=rawline', $path);

    $self->_debug("Parse lines: " . join(' ', map { "'$_'" } @command));
    $self->_debug_enter();

    if (!open($fh, '-|', @command)) {
	$self->_debug_exit();
	return undef;
    }

    $discr = 0;

    $self->_debug("Start new sequence");

    while (defined($line = <$fh>)) {
	chomp($line);

	if ($line =~ m|^\s+\[0x[0-9a-f]+\]\s+(.*)$|) {
	    $inst = $1;

	    if ($inst =~ m|^Set column to (\d+)$|) {
		$column = $1;
		next;
	    }

	    if ($inst =~ m|^Extended opcode 2: set Address to 0x([0-9a-f]+)$|) {
		$addr = hex('0x' . $1);
		next;
	    }

	    if ($inst =~ m|^Advance Line by -?\d+ to (\d+)$|) {
		$ln = $1;
		next;
	    }

	    if ($inst =~ m|^Special opcode \d+: advance Address by \d+ to 0x([0-9a-f]+) and Line by -?\d+ to (\d+)(?: \(view \d+\))?$|) {
		($addr, $ln) = ($1, $2);
		$addr = hex('0x' . $addr);

		$self->_debug("Sequence [$addr] += ( '$dfile:$ln:$column' " .
			      ", $stmt , $discr )");

		push(@{$sequence->{$addr}},
		     [$dfile, $ln, $column, $stmt, $discr]);

		$discr = 0;
		next;
	    }

	    if ($inst =~ m|^Copy(?: \(view \d+\))?$|) {
		$self->_debug("Sequence [$addr] += ( '$dfile:$ln:$column' " .
			      ", $stmt , $discr )");

		push(@{$sequence->{$addr}},
		     [$dfile, $ln, $column, $stmt, $discr]);

		$discr = 0;
		next;
	    }

	    if ($inst =~ m|^Set is_stmt to (\d+)$|) {
		$stmt = $1;
		next;
	    }

	    if ($inst =~ m|^Advance PC by -?\d+ to 0x([0-9a-f]+)$|) {
		$addr = hex('0x' . $1);
		next;
	    }

	    if ($inst =~ m|^Advance PC by constant -?\d+ to 0x([0-9a-f]+)$|) {
		$addr = hex('0x' . $1);
		next;
	    }

	    if ($inst =~ m|^Extended opcode \d+: set Discriminator to (\d+)$|) {
		$discr = $1;
		next;
	    }

	    if ($inst =~ m|^Set File Name to entry (\d+) in the File Name Table$|) {
		$dfile = $ftable->{$1};
		next;
	    }

	    if ($inst =~ m|^Extended opcode \d+: End of Sequence$|) {
		$self->_debug("Sequence [$addr] += ( '$dfile:$ln:$column' " .
			      ", $stmt , $discr )");

		push(@{$sequence->{$addr}},
		     [$dfile, $ln, $column, $stmt, $discr]);
		push(@$table, $sequence);

		$self->_debug("Start new sequence");

		$sequence = {};
		$dfile = $ftable->{1};
		$addr = 0;
		$ln = 1;
		$column = 0;
		$discr = 0;
		next;
	    }

	    $self->_debug("Unknown instruction : '$inst'");
	    printf(STDERR "Unknown instruction: %s\n", $inst);
	    next;
	}

	if ($line =~ m|^\s+(\d+)\s+(\d+)\s+\(.*\):\s+(.*)$|) {
	    ($findex, $dindex, $file) = ($1, $2, $3);

	    if ($dindex != 0) {
		$file = $dtable->{$dindex} . '/' . $file;
	    }

	    $self->_debug("File table [$findex] = '$file'");

	    $ftable->{$findex} = $file;

	    if ($findex == 1) {
		$dfile = $ftable->{1};
	    }

	    next;
	}

	if ($line =~ m|^\s+(\d+)\s+\(.*\):\s+(.*)$|) {
	    ($dindex, $dir) = ($1, $2);

	    $self->_debug("Directory table [$dindex] = '$dir'");

	    $dtable->{$dindex} = $dir;
	    next;
	}

	if ($line =~ m|^\s+Initial value of 'is_stmt':\s+(\d)$|) {
	    $stmt = $1;
	    next;
	}

	if ($line =~ m|^\s+Opcode.*$|) {
	    next;
	} elsif ($line =~ m/^\s+.*:\s+-?(?:0x[0-9a-f]+|\d+)$/) {
	    next;
	} elsif ($line =~ m|^\s+The .* Table \(offset .*\):$|) {
	    next;
	} elsif ($line =~ m|^\s+Line Number Statements:$|) {
	    next;
	} elsif ($line =~ m|^\s+Entry\s+Name$|) {
	    next;
	} elsif ($line =~ m|^\s+Entry\s+Dir\s+Name$|) {
	    next;
	} elsif($line eq 'Raw dump of debug contents of section .debug_line:'){
	    next;
	} elsif ($line =~ m|^.*\S:\s+file format .*$|) {
	    next;
	} elsif ($line =~ m|^\s+No Line Number Statements.$|) {
	    next;
	} elsif ($line eq '') {
	    next;
	}

	$self->_debug("Unknown line : '$line'");
	printf(STDERR "Unknown line: %s\n", $line);
    }

    close($fh);

    $self->{_lines} = $table;

    $self->_update_info($ftable);

    $self->_debug_exit();
    return $self;
}

# Update the debug info by replacing the file indices by filenames in $ftable.
# Take the $ftable argument which is like follows:
#
# $ftable = { INT(1) => STRING(2) }
#   A table which gives for a given file index(1) the filename(2).
#
# Update the $self->{_info} field so it is like follows:
#
# $self->{_info} = { STRING(1) => [ STRING(2), INT(3) ] }
#   A table which gives for a given entry name(1) (see `_parse_code()`) the
#   file name(2) and the line number(3) of the source file defining the
#   corresponding function.
#
sub _update_info
{
    my ($self, $ftable) = @_;
    my ($info, $name, $findex, $file);

    $info = $self->{_info};

    foreach $name (keys(%$info)) {
	$findex = $info->{$name}->[0];
	$file = $ftable->{$findex};

	$self->_debug("Update debug info: '$name' => [ '$file' , " .
		      $info->{$name}->[1] . " ]");

	$info->{$name}->[0] = $file;
    }
}

# Get the bounds of a section with the given $section name.
# More precisely, for a section name such like $self->{_code}->{$section}
# exists (see `_parse_code()`), return a pair [ INT(1), INT(2) ] of the
# smallest address(1) of the section and the smallest address(2) immediately
# following the section (so the difference between (1) and (2) is the effective
# section size).
#
sub _get_section_bounds
{
    my ($self, $section) = @_;
    my ($min, $max, $entry, $start, $end, $bin);

    foreach $entry (keys(%{$self->{_code}->{$section}})) {
	$start = $self->{_code}->{$section}->{$entry}->[0]->[CODE_ADDR];
	$end = $self->{_code}->{$section}->{$entry}->[-1]->[CODE_ADDR];
	$bin = $self->{_code}->{$section}->{$entry}->[-1]->[CODE_BIN];
	$bin =~ s/ //g;
	$end += length($bin) / 2;

	if (!defined($min) || ($start < $min)) {
	    $min = $start;
	}

	if (!defined($max) || ($end > $max)) {
	    $max = $end;
	}
    }

    return [ $min, $max ];
}

# Filter sections smaller than a sequence.
#
# A debug line sequence is about contiguous addresses. As a consequence, a
# debug line sequence cannot be larger (or about a disjoint address range) than
# the section it refers to.
#
# Change the given $matching table to remove incompatible sequence - sections
# associations.
#
sub _filter_sections_by_size
{
    my ($self, $matching) = @_;
    my ($section, %secbounds, $start, $end);
    my ($index, $sequence, @addrs);

    foreach $section (keys(%{$self->{_code}})) {
	($start, $end) = @{$self->_get_section_bounds($section)};
	$secbounds{$section} = [ $start, $end ];
    }

    $index = 0;

    foreach $sequence (@{$self->{_lines}}) {
	@addrs = sort { $a <=> $b } keys(%$sequence);
	$start = $addrs[0];
	$end = $addrs[-1];

	foreach $section (keys(%{$matching->[$index]})) {
	    if ($start < $secbounds{$section}->[0]) {
		delete($matching->[$index]->{$section});
		next;
	    }

	    if ($end > $secbounds{$section}->[1]) {
		delete($matching->[$index]->{$section});
		next;
	    }
	}

	$index += 1;
    }
}

# Filter sections already associated to a sequence.
#
# For each sequence having only one associated section in the given $matching
# structure, make the corresponding portion of this section exclusive to the
# sequence.
# Indeed, a sequence must relate to at least one section, and an address in a
# section must relate to at most one sequence.
#
# This function is a fixpoint.
#
# Note: Only makes portions (i.e. a range of address) of sections exclusive,
#       not complete section. This is because many sequences can relate to the
#       same section as long as the address ranges they refer to are disjoint.
#
sub _filter_sections_by_overlap
{
    my ($self, $matching) = @_;
    my ($index, $sequence, $section, @addrs, $start, $end);
    my (%reservation, $rstart, $rend, $overlap);

    do {
	$overlap = 0;

	$index = 0;

	foreach $sequence (@{$self->{_lines}}) {
	    if (scalar(%{$matching->[$index]}) != 1) {
		$index += 1;
		next;
	    }

	    $section = (keys(%{$matching->[$index]}))[0];
	    @addrs = sort { $a <=> $b } keys(%$sequence);
	    $start = $addrs[0];
	    $end = $addrs[-1];

	    $reservation{$section}->{$start} = $end;

	    $index += 1;
	}

	$index = 0;

	foreach $sequence (@{$self->{_lines}}) {
	    if (scalar(%{$matching->[$index]}) <= 1) {
		$index += 1;
		next;
	    }

	    @addrs = sort { $a <=> $b } keys(%$sequence);
	    $start = $addrs[0];
	    $end = $addrs[-1];

	    foreach $section (keys(%{$matching->[$index]})) {
		foreach $rstart (keys(%{$reservation{$section}})) {
		    $rend = $reservation{$section}->{$rstart};

		    if ((($start >= $rstart) && ($start <= $rend)) ||
			(($end >= $rstart) && ($end <= $rend)) ||
			(($start < $rstart) && ($end > $rend))) {

			$overlap = 1;
			delete($matching->[$index]->{$section});
			last;
		    }
		}
	    }

	    $index += 1;
	}
    } while ($overlap == 1);
}

# Filter section by instruction address alignment.
#
# Some instruction sets like x86 have variable length instructions. Debug line
# sequences always associate instructions to source line by refering to the
# address of the first byte of the instruction.
# If a sequence refers to a byte which is in the middle of an instruction, then
# this sequence is not associated to the section containing this instruction.
#
# Note that the last entry of a debug line sequence can refer to an address
# outside of the section.
#
sub _filter_sections_by_addr_align
{
    my ($self, $matching) = @_;
    my ($index, $sequence, $addr, $section, %secaddrs, $entry, $inst);
    my (@addrs, @allowed, $last, $miss);

    $index = 0;

    foreach $sequence (@{$self->{_lines}}) {
	if (scalar(%{$matching->[$index]}) <= 1) {
	    $index += 1;
	    next;
	}

	foreach $section (keys(%{$matching->[$index]})) {
	    if (!defined($secaddrs{$section})) {
		foreach $entry (keys(%{$self->{_code}->{$section}})) {
		    foreach $inst (@{$self->{_code}->{$section}->{$entry}}) {
			$secaddrs{$section}->{$inst->[CODE_ADDR]} = 1;
		    }
		}
	    }

	    $miss = 0;
	    @addrs = sort { $a <=> $b } keys(%$sequence);
	    @allowed = sort { $a <=> $b } keys(%{$secaddrs{$section}});

	    # There can be a debug_line for the address right after the end of
	    # the section.
	    if ($addrs[-1] > $allowed[-1]) {
		pop(@addrs);
	    }

	    foreach $addr (@addrs) {
		if (!defined($secaddrs{$section}->{$addr})) {
		    $miss += 1;
		    last;
		}
	    }

	    if ($miss > 0) {
		delete($matching->[$index]->{$section});
	    }
	}

	$index += 1;
    }
}

# Filter section by subprogram symbol matching.
#
# The information extracted from the debug info (see `_parse_info()`)
# associates some function symbols to a pair (filename, line).
# Moreover, the information extracted from the symbol table (see
# `_parse_symbols()`) associate every symbol with a unique section and address.
#
# Try to find for each sequence, the subprogram (function/method) symbols it
# refers to (using the symbol table information) and compare the pair
# (filename, line) the sequence gives for the symbol address to the pair
# (filename, line) the debug info gives for the symbol.
#
# Due to debug information imprecision, the match can be not exact or there can
# be not match at all.
# However, if for a given sequence, there is at least one approximative match
# with at least one section, then with a good probability, the true matching
# section is one of them and we can eliminate the potential matching with the
# other sections.
#
# Note: In this function we compute a matching score: lower score means better
#       matching. We do not use this score but it could be useful for future
#       work.
#
sub _filter_sections_by_symbol
{
    my ($self, $matching) = @_;
    my ($index, $sequence, $section, $addr, $symbol, $end, $info, $file, $ln);
    my ($insts, $inst, $ifile, $iln, $dist, $numdist, $sumdist, $avgdist);
    my ($dists, %seqdists, $pair);

    $index = 0;

    foreach $sequence (@{$self->{_lines}}) {
	if (scalar(%{$matching->[$index]}) <= 1) {
	    $index += 1;
	    next;
	}

	foreach $section (keys(%{$matching->[$index]})) {
	    $dists = [];

	    foreach $addr (keys(%{$self->{_symbols}->{$section}})) {
		foreach $pair (@{$self->{_symbols}->{$section}->{$addr}}) {
		    ($symbol, $end) = @$pair;

		    $info = $self->{_info}->{$symbol};
		    if (!defined($info)) {
			next;
		    }

		    ($file, $ln) = @$info;

		    $numdist = 0;
		    $sumdist = 0;
		    $insts = $self->{_lines}->[$index]->{$addr};

		    foreach $inst (@$insts) {
			($ifile, $iln) = @$inst;

			if (($ifile ne $file) || ($iln < $ln)) {
			    next;
			}

			$dist = $iln - $ln;
			$numdist += 1;
			$sumdist += $dist;
		    }

		    if ($numdist > 0) {
			$avgdist = $sumdist / $numdist;
			push(@$dists, $avgdist);
		    }
		}
	    }

	    if (scalar(@$dists) > 0) {
		$seqdists{$index}->{$section} = $dists;
	    }
	}

	if (defined($seqdists{$index})) {
	    foreach $section (keys(%{$matching->[$index]})) {
		if (!defined($seqdists{$index}->{$section})) {
		    delete($matching->[$index]->{$section});
		}
	    }
	}

	$index += 1;
    }
}

# Check if no two sequences in the matching structure is associated with the
# same range of address on the same section.
# If so, computes a matching table as described in `_match_sections()`, put it
# in $self->{_matching} and return 1.
# Otherwise, return 0.
#
sub _try_complete_matching
{
    my ($self, $matching) = @_;
    my ($index, $sequence, @addrs, $start, $end, $section);
    my ($table);

    $index = 0;

    foreach $sequence (@{$self->{_lines}}) {
	@addrs = sort { $a <=> $b } keys(%$sequence);
	$start = $addrs[0];
	$end = $addrs[-1];

	foreach $section (keys(%{$matching->[$index]})) {
	    push(@{$table->{$section}->{$start}}, [ $sequence, $end ]);
	}

	$index += 1;
    }

    foreach $section (keys(%$table)) {
	$end = -1;

	foreach $start (sort { $a <=> $b } keys(%{$table->{$section}})) {
	    if (scalar(@{$table->{$section}->{$start}}) > 1) {
		return 0;
	    }

	    if ($start <= $end) {
		return 0;
	    }

	    $end = $table->{$section}->{$start}->[0]->[1];
	    $table->{$section}->{$start} = $table->{$section}->{$start}->[0];
	}
    }

    $self->{_matching} = $table;

    return 1;
}

# Force an association between sequences and sections.
# When two sequences conflict for the same address range in the same section,
# the heuristic is to pick the largest sequence.
#
sub _complete_matching_best_effort
{
    my ($self, $matching) = @_;
    my ($index, $sequence, @addrs, $start, $end, $section);
    my ($table, $ostart, $oend, $conflicts, $cstart, $cend);

    $index = 0;

    foreach $sequence (@{$self->{_lines}}) {
	@addrs = sort { $a <=> $b } keys(%$sequence);
	$start = $addrs[0];
	$end = $addrs[-1];

	foreach $section (keys(%{$matching->[$index]})) {
	    $conflicts = 0;
	    $oend = -1;

	    foreach $ostart (sort { $a <=> $b } keys(%{$table->{$section}})) {
		$oend = $table->{$section}->{$ostart}->[1];

		if ((($start >= $ostart) && ($start <= $oend)) ||
		    (($end >= $ostart) && ($end <= $oend)) ||
		    (($start < $ostart) && ($end > $oend))) {
		    $conflicts += 1;

		    $cstart = $ostart;
		    $cend = $oend;

		    if ($conflicts > 1) {
			last;
		    }
		}
	    }

	    if ($conflicts > 1) {
		next;
	    }

	    if ($conflicts == 1) {
		if (($end - $start) > ($cend - $cstart)) {
		    delete($table->{$section}->{$cstart});
		} else {
		    next;
		}
	    }

	    $table->{$section}->{$start} = [ $sequence, $end ];
	}

	$index += 1;
    }

    $self->{_matching} = $table;
}

# Find sequences in $self->{_lines} which are identical.
# Return the following structure:
#
# return { INT(1) => INT(2) }
#   A table indicating that the sequence at a given index(1) in $self->{_lines}
#   is exactly the same than another sequence with the pointed index(2).
#   If an index is pointed (as a value) it does not appear as a pointer (key).
#
sub _trim_identical_sequences
{
    my ($self) = @_;
    my ($len, $i, $j, $iseq, $jseq, $diff, $addr, $iinsts, $jinsts, $k, $e);
    my (%sieve);

    $len = scalar(@{$self->{_lines}});

    for ($i = 1; $i < $len; $i++) {
	$iseq = $self->{_lines}->[$i];

	for ($j = 0; $j < $i; $j++) {
	    if (defined($sieve{$j})) {
		next;
	    }

	    $jseq = $self->{_lines}->[$j];

	    if (scalar(%$jseq) != scalar(%$iseq)) {
		next;
	    }

	    $diff = 0;

	    foreach $addr (keys(%$iseq)) {
		if (!defined($jseq->{$addr})) {
		    $diff = 1;
		    last;
		}

		$iinsts = $iseq->{$addr};
		$jinsts = $jseq->{$addr};

		if (scalar(@$iinsts) != scalar(@$jinsts)) {
		    $diff = 1;
		    last;
		}

		for ($k = 0; $k < scalar(@$iinsts); $k++) {
		    for ($e = 0; $e < scalar(@{$iinsts->[$k]}); $e++) {
			if ($iinsts->[$k]->[$e] ne $jinsts->[$k]->[$e]) {
			    $diff = 1;
			    last;
			}
		    }
		}
	    }

	    if ($diff == 1) {
		next;
	    }

	    $sieve{$i} = $j;
	    last;
	}
    }

    return \%sieve;
}

# Match debug line sequences to sections.
#
# Compilers emit matching between assembly instruction addresses and source
# code lines in the form of one of more debug line sequences.
# As far as I know, there is no direct way to associate a sequence to a
# section. Because of that, given a section and an address within this section,
# there is no way to tell in which sequence to look. Specifically, there can
# be more than one sequence which gives a source code line for the same
# address.
#
# This function use different mechanism to associate each pair (section,
# address) with a unique sequence. It does so by using a matching structure
# which looks like follows:
#
# $matching = [ INT(1) = { STRING(2) => 1 } ]
#   A list of set of section names(2). A set at a given index(1) `i` contains
#   the names of all the sections that potentially refer to the sequence at
#   index `i` in $self->{_lines}.
#
# This matching structure is trimed by successive filters. After each filter,
# the function `_try_complete_matching()` checks if each section can be
# associated with a unique sequence. If this function still fails after every
# filters, the function `_complete_matching_best_effort()` makes an arbitrary
# association.
#
# Note that while a (section, address) pair is associated to a unique sequence,# many pairs can be associated to the same sequence.
#
# Fills the following field of $self:
#
# $self->{_matching} = { STRING(1) => { INT(2) => [ SEQUENCE(3) , INT(4) ] } }
#   A multi-level table which gives for a section name(1) and a start
#   address(2), the associated debug sequence(3) and the end address(4) (the
#   address of the last instruction with a debug line).
#   The SEQUENCE structure is the one stored in $self->{_lines} (see
#   `_parse_lines()`).
#
sub _match_sections
{
    my ($self) = @_;
    my ($sieve, $index, $sequence, $section, @matching);

    # Some compiler sometimes produce sets of identical line sequences.
    # There is no point processing them all. Keep only one instance of each
    # group of identical sequences.
    #
    $sieve = $self->_trim_identical_sequences();

    $index = 0;

    # Fill the matching structure with every sections as a potential
    # association for every sequence.
    #
    foreach $sequence (@{$self->{_lines}}) {
	push(@matching, {});

	if (!defined($sieve->{$index})) {
	    foreach $section (keys(%{$self->{_code}})) {
		$matching[-1]->{$section} = 1;
	    }
	}

	$index += 1;
    }

    $self->_filter_sections_by_size(\@matching);

    if ($self->_try_complete_matching(\@matching)) {
	return $self;
    }

    $self->_filter_sections_by_overlap(\@matching);

    if ($self->_try_complete_matching(\@matching)) {
	return $self;
    }

    $self->_filter_sections_by_addr_align(\@matching);

    if ($self->_try_complete_matching(\@matching)) {
	return $self;
    }

    $self->_filter_sections_by_symbol(\@matching);

    if ($self->_try_complete_matching(\@matching)) {
	return $self;
    }

    $self->_filter_sections_by_overlap(\@matching);

    if ($self->_try_complete_matching(\@matching)) {
	return $self;
    }

    $self->_complete_matching_best_effort(\@matching);

    return $self;
}




sub sections
{
    my ($self) = @_;

    return [ @{$self->{_sections}} ];
}

sub entries
{
    my ($self, $section) = @_;
    my $section_code = $self->{_code}->{$section};

    if (!defined($section_code)) {
	return undef;
    }

    return [ sort { $section_code->{$a}->[0]->[CODE_ADDR] <=>
	            $section_code->{$b}->[0]->[CODE_ADDR] }
	     keys(%$section_code) ];
}

sub code
{
    my ($self, $section, $entry) = @_;
    my ($section_code, $entry_code, $line, @ret);

    $section_code = $self->{_code}->{$section};
    if (!defined($section_code)) {
	return undef;
    }

    $entry_code = $section_code->{$entry};
    if (!defined($entry_code)) {
	return undef;
    }

    foreach $line (@$entry_code) {
	push(@ret, [ @$line ]);
    }

    return \@ret;
}

sub lines
{
    my ($self, $section, $addr) = @_;
    my ($entry, $start, $sequence, $end, $ret);

    $entry = $self->{_matching}->{$section};

    foreach $start (sort { $a <=> $b } keys(%$entry)) {
	if ($start > $addr) {
	    return undef;
	}

	($sequence, $end) = @{$entry->{$start}};

	if ($end < $addr) {
	    next;
	}

	$ret = $sequence->{$addr};

	if (defined($ret)) {
	    return [ @$ret ];
	} else {
	    return undef;
	}
    }

    return undef;
}

sub compdir
{
    my ($self) = @_;

    return $self->{_compdir};
}


1;
__END__
