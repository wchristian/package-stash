package Package::Stash;
use strict;
use warnings;
# ABSTRACT: routines for manipulating stashes

use Carp qw(confess);
use Scalar::Util qw(reftype);
use Symbol;

use XSLoader;
XSLoader::load(
    __PACKAGE__,
    # we need to be careful not to touch $VERSION at compile time, otherwise
    # DynaLoader will assume it's set and check against it, which will cause
    # fail when being run in the checkout without dzil having set the actual
    # $VERSION
    exists $Package::Stash::{VERSION}
        ? ${ $Package::Stash::{VERSION} } : (),
);

# before 5.12, assigning to the ISA glob would make it lose its magical ->isa
# powers
use constant BROKEN_ISA_ASSIGNMENT => ($] < 5.012);

=head1 SYNOPSIS

  my $stash = Package::Stash->new('Foo');
  $stash->add_package_symbol('%foo', {bar => 1});
  # $Foo::foo{bar} == 1
  $stash->has_package_symbol('$foo') # false
  my $namespace = $stash->namespace;
  *{ $namespace->{foo} }{HASH} # {bar => 1}

=head1 DESCRIPTION

Manipulating stashes (Perl's symbol tables) is occasionally necessary, but
incredibly messy, and easy to get wrong. This module hides all of that behind a
simple API.

NOTE: Most methods in this class require a variable specification that includes
a sigil. If this sigil is absent, it is assumed to represent the IO slot.

=method new $package_name

Creates a new C<Package::Stash> object, for the package given as the only
argument.

=method name

Returns the name of the package that this object represents.

=method namespace

Returns the raw stash itself.

=cut

{
    my %SIGIL_MAP = (
        '$' => 'SCALAR',
        '@' => 'ARRAY',
        '%' => 'HASH',
        '&' => 'CODE',
        ''  => 'IO',
    );

    sub _deconstruct_variable_name {
        my ($self, $variable) = @_;

        (defined $variable && length $variable)
            || confess "You must pass a variable name";

        my $sigil = substr($variable, 0, 1, '');

        if (exists $SIGIL_MAP{$sigil}) {
            return ($variable, $sigil, $SIGIL_MAP{$sigil});
        }
        else {
            return ("${sigil}${variable}", '', $SIGIL_MAP{''});
        }
    }
}

=method add_package_symbol $variable $value %opts

Adds a new package symbol, for the symbol given as C<$variable>, and optionally
gives it an initial value of C<$value>. C<$variable> should be the name of
variable including the sigil, so

  Package::Stash->new('Foo')->add_package_symbol('%foo')

will create C<%Foo::foo>.

Valid options (all optional) are C<filename>, C<first_line_num>, and
C<last_line_num>.

C<$opts{filename}>, C<$opts{first_line_num}>, and C<$opts{last_line_num}> can
be used to indicate where the symbol should be regarded as having been defined.
Currently these values are only used if the symbol is a subroutine ('C<&>'
sigil) and only if C<$^P & 0x10> is true, in which case the special C<%DB::sub>
hash is updated to record the values of C<filename>, C<first_line_num>, and
C<last_line_num> for the subroutine. If these are not passed, their values are
inferred (as much as possible) from C<caller> information.

This is especially useful for debuggers and profilers, which use C<%DB::sub> to
determine where the source code for a subroutine can be found.  See
L<http://perldoc.perl.org/perldebguts.html#Debugger-Internals> for more
information about C<%DB::sub>.

=cut

sub _valid_for_type {
    my $self = shift;
    my ($value, $type) = @_;
    if ($type eq 'HASH' || $type eq 'ARRAY'
     || $type eq 'IO'   || $type eq 'CODE') {
        return reftype($value) eq $type;
    }
    else {
        my $ref = reftype($value);
        return !defined($ref) || $ref eq 'SCALAR' || $ref eq 'REF' || $ref eq 'LVALUE';
    }
}

sub add_package_symbol {
    my ($self, $variable, $initial_value, %opts) = @_;

    my ($name, $sigil, $type) = ref $variable eq 'HASH'
        ? @{$variable}{qw[name sigil type]}
        : $self->_deconstruct_variable_name($variable);

    my $pkg = $self->name;

    if (@_ > 2) {
        $self->_valid_for_type($initial_value, $type)
            || confess "$initial_value is not of type $type";

        # cheap fail-fast check for PERLDBf_SUBLINE and '&'
        if ($^P and $^P & 0x10 && $sigil eq '&') {
            my $filename = $opts{filename};
            my $first_line_num = $opts{first_line_num};

            (undef, $filename, $first_line_num) = caller
                if not defined $filename;

            my $last_line_num = $opts{last_line_num} || ($first_line_num ||= 0);

            # http://perldoc.perl.org/perldebguts.html#Debugger-Internals
            $DB::sub{$pkg . '::' . $name} = "$filename:$first_line_num-$last_line_num";
        }
    }

    no strict 'refs';
    no warnings 'redefine', 'misc', 'prototype';
    *{$pkg . '::' . $name} = ref $initial_value ? $initial_value : \$initial_value;
}

=method remove_package_glob $name

Removes all package variables with the given name, regardless of sigil.

=method has_package_symbol $variable

Returns whether or not the given package variable (including sigil) exists.

=cut

sub has_package_symbol {
    my ($self, $variable) = @_;

    my ($name, $sigil, $type) = ref $variable eq 'HASH'
        ? @{$variable}{qw[name sigil type]}
        : $self->_deconstruct_variable_name($variable);

    my $namespace = $self->namespace;

    return unless exists $namespace->{$name};

    my $entry_ref = \$namespace->{$name};
    if (reftype($entry_ref) eq 'GLOB') {
        # XXX: assigning to any typeglob slot also initializes the SCALAR slot,
        # and saying that an undef scalar variable doesn't exist is probably
        # vaguely less surprising than a scalar variable popping into existence
        # without anyone defining it
        if ($type eq 'SCALAR') {
            return defined ${ *{$entry_ref}{$type} };
        }
        else {
            return defined *{$entry_ref}{$type};
        }
    }
    else {
        # a symbol table entry can be -1 (stub), string (stub with prototype),
        # or reference (constant)
        return $type eq 'CODE';
    }
}

=method get_package_symbol $variable

Returns the value of the given package variable (including sigil).

=cut

sub get_package_symbol {
    my ($self, $variable, %opts) = @_;

    my ($name, $sigil, $type) = ref $variable eq 'HASH'
        ? @{$variable}{qw[name sigil type]}
        : $self->_deconstruct_variable_name($variable);

    my $namespace = $self->namespace;

    if (!exists $namespace->{$name}) {
        if ($opts{vivify}) {
            if ($type eq 'ARRAY') {
                if (BROKEN_ISA_ASSIGNMENT) {
                    $self->add_package_symbol(
                        $variable,
                        $name eq 'ISA' ? () : ([])
                    );
                }
                else {
                    $self->add_package_symbol($variable, []);
                }
            }
            elsif ($type eq 'HASH') {
                $self->add_package_symbol($variable, {});
            }
            elsif ($type eq 'SCALAR') {
                $self->add_package_symbol($variable);
            }
            elsif ($type eq 'IO') {
                $self->add_package_symbol($variable, Symbol::geniosym);
            }
            elsif ($type eq 'CODE') {
                confess "Don't know how to vivify CODE variables";
            }
            else {
                confess "Unknown type $type in vivication";
            }
        }
        else {
            if ($type eq 'CODE') {
                # this effectively "de-vivifies" the code slot. if we don't do
                # this, referencing the coderef at the end of this function
                # will cause perl to auto-vivify a stub coderef in the slot,
                # which isn't what we want
                $self->add_package_symbol($variable);
            }
        }
    }

    my $entry_ref = \$namespace->{$name};

    if (ref($entry_ref) eq 'GLOB') {
        return *{$entry_ref}{$type};
    }
    else {
        if ($type eq 'CODE') {
            no strict 'refs';
            return \&{ $self->name . '::' . $name };
        }
        else {
            return undef;
        }
    }
}

=method get_or_add_package_symbol $variable

Like C<get_package_symbol>, except that it will return an empty hashref or
arrayref if the variable doesn't exist.

=cut

sub get_or_add_package_symbol {
    my $self = shift;
    $self->get_package_symbol(@_, vivify => 1);
}

=method remove_package_symbol $variable

Removes the package variable described by C<$variable> (which includes the
sigil); other variables with the same name but different sigils will be
untouched.

=cut

sub remove_package_symbol {
    my ($self, $variable) = @_;

    my ($name, $sigil, $type) = ref $variable eq 'HASH'
        ? @{$variable}{qw[name sigil type]}
        : $self->_deconstruct_variable_name($variable);

    # FIXME:
    # no doubt this is grossly inefficient and
    # could be done much easier and faster in XS

    my ($scalar_desc, $array_desc, $hash_desc, $code_desc, $io_desc) = (
        { sigil => '$', type => 'SCALAR', name => $name },
        { sigil => '@', type => 'ARRAY',  name => $name },
        { sigil => '%', type => 'HASH',   name => $name },
        { sigil => '&', type => 'CODE',   name => $name },
        { sigil => '',  type => 'IO',     name => $name },
    );

    my ($scalar, $array, $hash, $code, $io);
    if ($type eq 'SCALAR') {
        $array  = $self->get_package_symbol($array_desc)  if $self->has_package_symbol($array_desc);
        $hash   = $self->get_package_symbol($hash_desc)   if $self->has_package_symbol($hash_desc);
        $code   = $self->get_package_symbol($code_desc)   if $self->has_package_symbol($code_desc);
        $io     = $self->get_package_symbol($io_desc)     if $self->has_package_symbol($io_desc);
    }
    elsif ($type eq 'ARRAY') {
        $scalar = $self->get_package_symbol($scalar_desc);
        $hash   = $self->get_package_symbol($hash_desc)   if $self->has_package_symbol($hash_desc);
        $code   = $self->get_package_symbol($code_desc)   if $self->has_package_symbol($code_desc);
        $io     = $self->get_package_symbol($io_desc)     if $self->has_package_symbol($io_desc);
    }
    elsif ($type eq 'HASH') {
        $scalar = $self->get_package_symbol($scalar_desc);
        $array  = $self->get_package_symbol($array_desc)  if $self->has_package_symbol($array_desc);
        $code   = $self->get_package_symbol($code_desc)   if $self->has_package_symbol($code_desc);
        $io     = $self->get_package_symbol($io_desc)     if $self->has_package_symbol($io_desc);
    }
    elsif ($type eq 'CODE') {
        $scalar = $self->get_package_symbol($scalar_desc);
        $array  = $self->get_package_symbol($array_desc)  if $self->has_package_symbol($array_desc);
        $hash   = $self->get_package_symbol($hash_desc)   if $self->has_package_symbol($hash_desc);
        $io     = $self->get_package_symbol($io_desc)     if $self->has_package_symbol($io_desc);
    }
    elsif ($type eq 'IO') {
        $scalar = $self->get_package_symbol($scalar_desc);
        $array  = $self->get_package_symbol($array_desc)  if $self->has_package_symbol($array_desc);
        $hash   = $self->get_package_symbol($hash_desc)   if $self->has_package_symbol($hash_desc);
        $code   = $self->get_package_symbol($code_desc)   if $self->has_package_symbol($code_desc);
    }
    else {
        confess "This should never ever ever happen";
    }

    $self->remove_package_glob($name);

    $self->add_package_symbol($scalar_desc => $scalar);
    $self->add_package_symbol($array_desc  => $array)  if defined $array;
    $self->add_package_symbol($hash_desc   => $hash)   if defined $hash;
    $self->add_package_symbol($code_desc   => $code)   if defined $code;
    $self->add_package_symbol($io_desc     => $io)     if defined $io;
}

=method list_all_package_symbols $type_filter

Returns a list of package variable names in the package, without sigils. If a
C<type_filter> is passed, it is used to select package variables of a given
type, where valid types are the slots of a typeglob ('SCALAR', 'CODE', 'HASH',
etc). Note that if the package contained any C<BEGIN> blocks, perl will leave
an empty typeglob in the C<BEGIN> slot, so this will show up if no filter is
used (and similarly for C<INIT>, C<END>, etc).

=cut

sub list_all_package_symbols {
    my ($self, $type_filter) = @_;

    my $namespace = $self->namespace;
    return keys %{$namespace} unless defined $type_filter;

    # NOTE:
    # or we can filter based on
    # type (SCALAR|ARRAY|HASH|CODE)
    if ($type_filter eq 'CODE') {
        return grep {
            # any non-typeglob in the symbol table is a constant or stub
            ref(\$namespace->{$_}) ne 'GLOB'
                # regular subs are stored in the CODE slot of the typeglob
                || defined(*{$namespace->{$_}}{CODE})
        } keys %{$namespace};
    }
    elsif ($type_filter eq 'SCALAR') {
        return grep {
            ref(\$namespace->{$_}) eq 'GLOB'
                && defined(${*{$namespace->{$_}}{'SCALAR'}})
        } keys %{$namespace};
    }
    else {
        return grep {
            ref(\$namespace->{$_}) eq 'GLOB'
                && defined(*{$namespace->{$_}}{$type_filter})
        } keys %{$namespace};
    }
}

=head1 BUGS

No known bugs.

Please report any bugs through RT: email
C<bug-package-stash at rt.cpan.org>, or browse to
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Package-Stash>.

=head1 SEE ALSO

=over 4

=item * L<Class::MOP::Package>

This module is a factoring out of code that used to live here

=back

=head1 SUPPORT

You can find this documentation for this module with the perldoc command.

    perldoc Package::Stash

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Package-Stash>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Package-Stash>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Package-Stash>

=item * Search CPAN

L<http://search.cpan.org/dist/Package-Stash>

=back

=head1 AUTHOR

Jesse Luehrs <doy at tozt dot net>

Mostly copied from code from L<Class::MOP::Package>, by Stevan Little and the
Moose Cabal.

=cut

1;
