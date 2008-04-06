use warnings;
use strict;

package Prophet::Replica::SVN;
use base qw/Prophet::Replica/;
use Params::Validate qw(:all);
use UNIVERSAL::require;

use SVN::Core;
use SVN::Ra;
use SVN::Delta;

use Prophet::Handle;
use Prophet::Replica::SVN::ReplayEditor;
use Prophet::Replica::SVN::Util;
use Prophet::ChangeSet;
use Prophet::Conflict;

__PACKAGE__->mk_accessors(qw/url ra prophet_handle pool/);

our $DEBUG = $Prophet::Handle::DEBUG;

=head2 setup

Open a connection to the SVN source identified by C<$self->url>.

=cut

sub _get_ra {
    my $self = shift;
    my ( $baton, $ref ) = SVN::Core::auth_open_helper( Prophet::Replica::SVN::Util->get_auth_providers );
    my $config = Prophet::Replica::SVN::Util->svnconfig;
    return SVN::Ra->new( url => $self->url, config => $config, auth => $baton, pool => $self->pool );
}

sub setup {
    my $self = shift;
    my $pool = SVN::Pool->new;

    $self->pool($pool);

    $self->ra( $self->_get_ra );
    if ( $self->url =~ /^file:\/\/(.*)$/ ) {
        $self->prophet_handle( Prophet::Handle->new( { repository => $1 } ) );
        $self->state_handle( $self->prophet_handle );
    }
    if ( $self->is_resdb ) {

        # XXX: should probably just point to self
        return;
    }

    my $res_url = $self->url;
    $res_url =~ s/(\_res|)$/_res/;
    $self->ressource( __PACKAGE__->new( { url => $res_url, is_resdb => 1 } ) );
}

=head2 uuid

Return the replica SVN repository's UUID

=cut

sub uuid {
    my $self = shift;
    return $self->prophet_handle->repo_handle->fs->get_uuid;
}

sub most_recent_changeset {
    my $self = shift;
     $self->ra->get_latest_revnum
}

sub fetch_changeset {
    my $self = shift;
    my $rev = shift;
        my $editor = Prophet::Replica::SVN::ReplayEditor->new( _debug => 0 );
        $editor->ra( $self->_get_ra );
        my $pool = SVN::Pool->new_default;

        # This horrible hack is here because I have no idea how to pass custom variables into the editor
        $editor->{revision} = $rev;

        $self->ra->replay( $rev, 0, 1, $editor );
        return $self->_recode_changeset( $editor->dump_deltas, $self->ra->rev_proplist($rev) );

}


sub _recode_changeset {
    my $self      = shift;
    my $entry     = shift;
    my $revprops  = shift;
    my $changeset = Prophet::ChangeSet->new(
        {   sequence_no          => $entry->{'revision'},
            source_uuid          => $self->uuid,
            original_source_uuid => $revprops->{'prophet:original-source'} || $self->uuid,
            original_sequence_no => $revprops->{'prophet:original-sequence-no'} || $entry->{'revision'},
            is_nullification     => ( ( $revprops->{'prophet:special-type'} || '' ) eq 'nullification' ) ? 1 : undef,
            is_resolution        => ( ( $revprops->{'prophet:special-type'} || '' ) eq 'resolution' ) ? 1 : undef,

        }
    );

    # add each node's changes to the changeset
    for my $path ( keys %{ $entry->{'paths'} } ) {
        if ( $path =~ qr|^(.+)/(.*?)/(.*?)$| ) {
            my ( $prefix, $type, $record ) = ( $1, $2, $3 );
            my $change = Prophet::Change->new(
                {   node_type   => $type,
                    node_uuid   => $record,
                    change_type => $entry->{'paths'}->{$path}->{fs_operation}
                }
            );
            for my $name ( keys %{ $entry->{'paths'}->{$path}->{prop_deltas} } ) {
                $change->add_prop_change(
                    name => $name,
                    old  => $entry->{paths}->{$path}->{prop_deltas}->{$name}->{'old'},
                    new  => $entry->{paths}->{$path}->{prop_deltas}->{$name}->{'new'},
                );
            }

            $changeset->add_change( change => $change );

        } else {
            warn "Discarding change to a non-record: $path" if $DEBUG;
        }

    }
    return $changeset;
}

sub record_integration_changeset {
    my $self = shift;
    $self->prophet_handle->begin_edit;
    $self->SUPER::record_integration_changeset(@_);
    $self->prophet_handle->commit_edit;
}

sub record_changeset {
    my $self = shift;
    $self->prophet_handle->record_changeset(@_);
}

sub record_resolutions {
    my $self = shift;
    $self->prophet_handle->record_resolutions( @_,
        $self->ressource ? $self->ressource->prophet_handle : $self->prophet_handle );
}

1;
