#!/usr/bin/perl
use strict;
use warnings;
use Flickr::API;
use Term::ReadLine;
use Data::Dumper;
use Dotenv -load;
use Getopt::Long;
use Pod::Usage;

my $dry_run = 0;
my $help = 0;

GetOptions(
    'dry-run' => \$dry_run,
    'help|h'  => \$help
) or pod2usage(2);

pod2usage(1) if $help;

# Check if environment variables are set
unless ($ENV{fkey} && $ENV{fsecret}) {
    die "ERROR: Required environment variables not set.\n" .
        "Please create a .env file with:\n" .
        "fkey=YOUR_FLICKR_API_KEY\n" .
        "fsecret=YOUR_FLICKR_API_SECRET\n" .
        "Or set them in your environment.\n";
}

if ($dry_run) {
    print "DRY RUN: No changes will be made to Flickr account or saved configuration\n\n";
    print "Using API Key: " . (substr($ENV{fkey}, 0, 10) . '...') . "\n";
    print "Environment variables are properly set.\n\n";
}

my $config_file = "$ENV{HOME}/saved-flickr.st";

my $term = Term::ReadLine->new('Testing Flickr::API');
$term->ornaments(0);
 
my $api = Flickr::API->new({
    'consumer_key'    => $ENV{fkey},
    'consumer_secret' => $ENV{fsecret},
});

print "Initializing Flickr OAuth authentication...\n";

my $rt_rc = $api->oauth_request_token({ 'callback' => 'https://127.0.0.1/' });

if ($rt_rc ne 'ok') {
    die "Failed to get OAuth request token: $rt_rc\n" .
        "Please check your API key and secret.\n";
}
 
my %request_token;
if ($rt_rc eq 'ok') {
    my $uri = $api->oauth_authorize_uri({ 'perms' => 'write' });

    print "\n" . "=" x 60 . "\n";
    print "FLICKR AUTHENTICATION REQUIRED\n";
    print "=" x 60 . "\n";
    print "Please visit this URL in your web browser:\n\n";
    print "$uri\n\n";
    print "=" x 60 . "\n";

    my $prompt = "Press [ENTER] after you have authenticated with Flickr and gotten the redirect: ";
    my $input = $term->readline($prompt);

    $prompt = "\nCopy the COMPLETE redirect URL from your browser address bar and paste it here:\nURL: ";
    $input = $term->readline($prompt);

    chomp($input);

    unless ($input =~ m{^https?://}) {
        die "Invalid URL provided. Please provide the complete redirect URL.\n";
    }

    my ($callback_returned, $token_received) = split(/\?/, $input);
    my @parms = split(/\&/, $token_received);
    foreach my $pair (@parms) {
        my ($key, $val) = split(/=/, $pair);
        $key =~ s/oauth_//;
        $request_token{$key} = $val;
    }
    
    unless ($request_token{token}) {
        die "Failed to extract OAuth token from redirect URL.\n" .
            "Please make sure you copied the complete URL after authentication.\n";
    }
}
 
print "Exchanging temporary token for access token...\n";
my $ac_rc = $api->oauth_access_token(\%request_token);

if ($ac_rc eq 'ok') {
    if ($dry_run) {
        print "\n" . "=" x 60 . "\n";
        print "DRY RUN COMPLETED SUCCESSFULLY\n";
        print "=" x 60 . "\n";
        print "Would save configuration to: $config_file\n";
        print "Would execute: flickr.auth.oauth.checkToken\n";
        print "Would execute: flickr.prefs.getPrivacy\n";
        print "Authentication would be successful!\n";
        print "=" x 60 . "\n";
    } else {
        $api->export_storable_config($config_file);
        print "✓ Configuration saved to $config_file\n";

        my $response = $api->execute_method('flickr.auth.oauth.checkToken');
        if ($response->{success}) {
            print "✓ Token verification successful\n";
        } else {
            warn "⚠ Token verification failed: " . $response->{error} . "\n";
        }

        $response = $api->execute_method('flickr.prefs.getPrivacy');
        if ($response->{success}) {
            print "✓ Privacy preferences retrieved successfully\n";
        } else {
            warn "⚠ Failed to retrieve privacy preferences: " . $response->{error} . "\n";
        }
        
        print "\n" . "=" x 60 . "\n";
        print "✅ FLICKR AUTHENTICATION COMPLETED SUCCESSFULLY!\n";
        print "=" x 60 . "\n";
        print "You can now use the saved configuration in other scripts.\n";
    }
} else {
    die "❌ OAuth access token request failed: $ac_rc\n" .
        "Please try the authentication process again.\n";
}

__END__

=head1 NAME

flickr_auth.pl - Flickr OAuth Authentication Script

=head1 SYNOPSIS

  flickr_auth.pl [options]

  Options:
    --dry-run    Show what would happen without making changes
    -h, --help   Display this help message

=head1 DESCRIPTION

This script performs OAuth authentication with Flickr and saves the
authentication tokens for future use. It will:

=over 4

=item 1. Request a temporary OAuth token from Flickr

=item 2. Provide a URL for you to authenticate in your web browser

=item 3. Exchange the temporary token for permanent access tokens

=item 4. Save the authentication configuration to ~/saved-flickr.st

=item 5. Verify the token and retrieve privacy preferences

=back

=head1 PREREQUISITES

=over 4

=item * Flickr API key and secret stored in .env file:

  fkey=YOUR_FLICKR_API_KEY
  fsecret=YOUR_FLICKR_API_SECRET

=item * Create a .env file in the same directory with your credentials:

  echo 'fkey=YOUR_API_KEY_HERE' > .env
  echo 'fsecret=YOUR_API_SECRET_HERE' >> .env

=item * Perl modules: Flickr::API, Term::ReadLine, Data::Dumper, Dotenv, Getopt::Long

=back

=head1 GETTING FLICKR API CREDENTIALS

1. Go to L<https://www.flickr.com/services/apps/create/apply>
2. Apply for a non-commercial API key
3. Once approved, create a new app at L<https://www.flickr.com/services/apps/create>
4. Copy the "Key" and "Secret" to your .env file

=head1 OPTIONS

=over 4

=item B<--dry-run>

Simulate the authentication process without actually saving configuration
or making permanent changes to your Flickr account.

=item B<-h, --help>

Display this help message and exit.

=back

=head1 USAGE EXAMPLES

  # Normal authentication
  ./flickr_auth.pl

  # Dry run to see what would happen
  ./flickr_auth.pl --dry-run

  # Show help
  ./flickr_auth.pl --help

=head1 AUTHENTICATION PROCESS

1. The script will display a Flickr authentication URL
2. Copy this URL and open it in your web browser
3. Log in to Flickr (if not already logged in) and authorize the application
4. Flickr will redirect you to a local URL - copy the entire redirect URL
5. Paste the redirect URL back into the script when prompted
6. The script will complete the OAuth handshake and save the tokens

=head1 TROUBLESHOOTING

=over 4

=item * Environment variables not set: Create a .env file with fkey and fsecret

=item * Authentication fails: Check your API key and secret

=item * Redirect URL issues: Make sure you copy the complete URL from browser

=back

=head1 CONFIGURATION FILE

The authentication tokens are saved to C<~/saved-flickr.st> in Storable format.
This file can be used by other Flickr::API scripts to authenticate without
going through the OAuth flow again.

=head1 SEE ALSO

L<Flickr::API>, L<https://www.flickr.com/services/api/>

=cut