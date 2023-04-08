package File::MultiTemp;

# ABSTRACT: manage a hash of temporary files

use v5.14;

use Moo;

use Fcntl qw/ LOCK_EX /;
use List::Util qw/ pairs /;
use Path::Tiny qw/ path /;
use PerlX::Maybe qw/ maybe /;
use Scalar::Util qw/ openhandle /;
use Types::Common::String qw/ SimpleStr /;
use Types::Standard       qw/ Bool CodeRef FileHandle HashRef StrMatch /;
use Types::Path::Tiny     qw/ Dir File /;

# RECOMMEND PREREQ: Type::Tiny::XS

use namespace::autoclean;

our $VERSION = 'v0.1.0';

=head1 SYNOPSIS

    my $files = File::MultiTemp->new(
      suffix   => '.csv',
      template => 'KEY-report-XXXX',
    );

    ...

    my @headers = ....

    my $csv = Text::CSV_XS->new( { binary => 1 } );

    my $fh = $files->file_handle( $key, sub {
        my ( $key, $path, $fh ) = @_;
        $csv->say( $fh, \@headings );
    } );

    $csv->say( $fh, $row );

    ...

    $files->close;

    my @reports = $files->files->@*;

=head1 DESCRIPTION

This class maintains a hash reference of objects and opened filehandles.

This is useful for maintaining several separate files, for example, several CSV reports based on company codes,
especially in cases where grouping the data may require a lot of work for the database.

=attr template

This is the filename template that is passed to L<File::Temp>. It should have a string of at least four Xs in a row,
which will be filled in with a unique string.

If it has the text "KEY" then that will be replaced by the hash key. Note that this should only be used if the hash key
is suitable for a filename.

This is optional.

=attr has_template

Returns true of L</template> is set.

=cut

has template => (
    is        => 'ro',
    isa       => StrMatch[ qr/XXXX/ ],
    predicate => 1,
);

=attr suffix

This is the filename suffix that is passed to L<File::Temp>. This is optional.

=attr has_suffix

Returns true if L</suffix> is set.

=cut

has suffix => (
    is        => 'ro',
    isa       => SimpleStr,
    predicate => 1,
);

=attr dir

This is the base directory that is passed to L<File::Temp>. This is optional.

=attr has_dir

Returns true if L</dir> is set.

=cut

has dir => (
    is        => 'ro',
    isa       => Dir,
    coerce    => \&path,
    predicate => 1,
);

=attr unlink

If this is true (default), then the files will be deleted after the object is destroyed.

=cut

has unlink => (
    is      => 'ro',
    isa     => Bool,
    default => 1,
);

=attr init

This is an optional function to initialise the file after it is created.

The function is calle with the three arguments:

=over

=item key

The hash key.

=item file

The L<Path::Tiny> object that was created.

You can use the C<cached_temp> method to access the original L<File::Temp> object.

=item fh

The file handle, which is an exclusive write lock on the file.

=back

=attr has_init

Returns true of L</init> is set.

=cut

has init => (
    is        => 'ro',
    isa       => CodeRef,
    predicate => 1,
);

has _files => (
    is      => 'ro',
    isa     => HashRef [ File ],
    builder => sub { return {} },
    init_arg => undef,
);

has _file_handles => (
    is      => 'ro',
    isa     => HashRef [ FileHandle ],
    builder => sub { return {} },
    init_arg => undef,
);

sub _get_tempfile_args {
    my ($self, $key ) = @_;

    my $template;

    if ( $self->has_template ) {
        $template = $self->template =~ s/KEY/${key}/r;
    }

    return (
        maybe TEMPLATE => $template,
        maybe SUFFIX   => $self->has_suffix ? $self->suffix : undef,
        maybe DIR      => $self->has_dir    ? $self->dir->stringify : undef,
              UNLINK   => $self->unlink,
    );

}

sub _get_open_file_handle {
    my ($self, $key, $file, $init) = @_;


   my $fhs = $self->_file_handles;
   if ( my $fh = openhandle( $fhs->{$key} ) ) {
       return $fh;
   }

   # get file only if we do not have it (otherwise recursion)
   $file //= $self->file( $key, $init );

   # filehandle is no longer be open, so overwrite it
   my $fh = ( $fhs->{$key} = $file->opena_raw( { locked => 0 } ) );

   # Path::Tiny locking does not seem to release locks properly, so we need to control locks manually
   flock( $fh, LOCK_EX );
   return $fh;
}

=method file

  my $path = $files->file( $key, \&init );

This returns a L<Path::Tiny> object of the created file.

A file handle will be opened, that can be accessed using L</file_handle>.

If a C<&init> function is passed, then it will be called, otherwise the L</init> function will be called,
with the parameters documented in the L</init> function.

=cut

sub file {
    my ($self, $key, $init) = @_;

    my $files = $self->_files;

    if ( my $file = $files->{$key} ) {
        return $file;
    }

    my $file = $files->{$key} //= Path::Tiny->tempfile( $self->_get_tempfile_args($key) );
    my $fh   = $self->_get_open_file_handle( $key, $file, $init );
    if ( $init //= $self->init ) {
        $init->( $key, $file, $fh );
    }
    return $file;
}

=method file_handle

  my $fh = $files->file_handle( $key, \&init );

This is a file handle used for writing.

If the filehandle does not exist, then it will be re-opened in append mode.

=cut

sub file_handle {
    my ($self, $key, $init) = @_;
    return $self->_get_open_file_handle( $key, undef, $init );
}

=method keys

This returns all files created.

=cut

sub keys {
    my ($self) = @_;
    my $files = $self->_files;
    return [ keys $files->%* ];
}

=method files

This returns all files created.

=cut

sub files {
    my ($self) = @_;
    my $files = $self->_files;
    return [ values $files->%* ];
}

=method close

This closes all files that are open.

This is called automatically when the object is destroyed.

=cut

sub close {
    my ($self) = @_;
    my $fhs = $self->_file_handles;
    for my $kv ( pairs $fhs->%* ) {
        my ( $key, $fh ) = $kv->@*;
        close($fh) if $fh;
        delete $fhs->{$key};
    }
}

sub DEMOLISH {
    my ($self, $is_global) = @_;
    $self->close unless $is_global;
}

=begin Pod::Coverage

  DEMOLISH

=end Pod::Coverage

=head1 append:AUTHOR

The initial development of this module was sponsored by Science Photo
Library L<https://www.sciencephoto.com>.

=head1 SEE ALSO

L<File::Temp>

L<Path::Tiny>

=cut

1;
