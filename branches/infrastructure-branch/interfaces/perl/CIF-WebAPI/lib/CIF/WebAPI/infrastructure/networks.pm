package CIF::WebAPI::infrastructure::networks;
use base 'CIF::WebAPI';

use strict;
use warnings;

use CIF::Message::SuspiciousNetwork;

sub GET {
    my ($self, $request, $response) = @_;

    my $detecttime = DateTime->from_epoch(epoch => (time() - (84600 * 90)));
    my @recs = CIF::Message::SuspiciousNetwork->search_feed($detecttime,10000);
    return CIF::WebAPI::infrastructure::generateFeed($response,@recs);
}

1;
