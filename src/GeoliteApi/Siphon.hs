{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DataKinds #-}

module GeoliteApi.Siphon
  ( getCsvs
  , replaceCsvs
  ) where

import           Codec.Archive.Zip
import           Colonnade                            ( Headed )
import           Control.DeepSeq                      ( NFData (rnf) )
import           Control.Exception                    ( evaluate )
import           Control.Monad                        ( guard, (<=<) )
import qualified Country                              as C
import qualified Data.ByteString.Char8                as B
import           Data.ByteString.Lazy                 ( fromStrict )
import qualified Data.ByteString.Streaming            as BS
import           Data.Compact                         ( compact, getCompact )
import           Data.Default
import qualified Data.Diet.Map.Strict.Unboxed.Lifted  as D
import           Data.IORef
import qualified Data.Map.Strict                      as MS
import           Data.Maybe                           ( fromJust )
import qualified Data.Text.Encoding                   as TE
import qualified Data.Text.IO                         as T
import           Data.Text.Short                      ( ShortText )
import qualified Data.Text.Short                      as TS
import           GeoliteApi.Types
import           Net.IPv4                             ( IPv4 )
import qualified Net.IPv4                             as IPv4
import           Net.IPv6                             ( IPv6 )
import qualified Net.IPv6                             as IPv6
import           Network.HTTP.Req
import qualified Siphon                               as SI
import qualified Streaming                            as SR
import qualified Streaming.Prelude                    as SR
import           System.Directory
import qualified System.IO                            as IO
import           System.Mem                           ( performMajorGC )

--------------------------------------------------------------------------------

-- Below are functions used to decode CSVs representing
-- different maps that the API uses to perform lookups.
siphonAsn :: SI.Siphon Headed B.ByteString (IPv4, IPv4, ASN)
siphonAsn = (\r asn -> (IPv4.lowerInclusive r,IPv4.upperInclusive r,asn))
  <$> SI.headed "network" ipv4Decode
  <*> ( ASN
        <$> SI.headed "autonomous_system_number" numDecode
        <*> SI.headed "autonomous_system_organization" shortTextDecode
      )

siphonAsnv6 :: SI.Siphon Headed B.ByteString (IPv6, IPv6, ASN)
siphonAsnv6 = (\r asn -> (IPv6.lowerInclusive r,IPv6.upperInclusive r,asn))
  <$> SI.headed "network" ipv6Decode
  <*> ( ASN
        <$> SI.headed "autonomous_system_number" numDecode
        <*> SI.headed "autonomous_system_organization" shortTextDecode
      )

siphonCountry :: SI.Siphon Headed B.ByteString (IPv4, IPv4, Country)
siphonCountry = (\r c -> (IPv4.lowerInclusive r,IPv4.upperInclusive r,c))
  <$> SI.headed "network" ipv4Decode
  <*> ( Country
        <$> SI.headed "geoname_id" numDecode
        <*> SI.headed "registered_country_geoname_id" numDecode
        <*> SI.headed "represented_country_geoname_id" numDecode
        <*> SI.headed "is_anonymous_proxy" boolDecode
        <*> SI.headed "is_satellite_provider" boolDecode
      )

siphonCountryV6 :: SI.Siphon Headed B.ByteString (IPv6, IPv6, Country)
siphonCountryV6 = (\r c -> (IPv6.lowerInclusive r,IPv6.upperInclusive r,c))
  <$> SI.headed "network" ipv6Decode
  <*> ( Country
        <$> SI.headed "geoname_id" numDecode
        <*> SI.headed "registered_country_geoname_id" numDecode
        <*> SI.headed "represented_country_geoname_id" numDecode
        <*> SI.headed "is_anonymous_proxy" boolDecode
        <*> SI.headed "is_satellite_provider" boolDecode
      )

siphonCountryLocations :: SI.Siphon Headed B.ByteString (Maybe Int, CountryLocation)
siphonCountryLocations = (\g cl -> (g,cl))
  <$> SI.headed "geoname_id" numDecode
  <*> ( CountryLocation
        <$> SI.headed "locale_code" shortTextDecode
        <*> SI.headed "continent_code" shortTextDecode
        <*> SI.headed "continent_name" shortTextDecode
        <*> SI.headed "country_iso_code" C.decodeUtf8
        <*> SI.headed "country_name" C.decodeUtf8
        <*> SI.headed "is_in_european_union" boolDecode
      )

siphonCityBlock :: SI.Siphon Headed B.ByteString (IPv4, IPv4, CityBlock)
siphonCityBlock = (\r cb -> (IPv4.lowerInclusive r,IPv4.upperInclusive r,cb))
  <$> SI.headed "network" ipv4Decode
  <*> ( CityBlock
        <$> SI.headed "geoname_id" maybeNumDecode
        <*> SI.headed "registered_country_geoname_id" maybeNumDecode
        <*> SI.headed "represented_country_geoname_id" maybeNumDecode
        <*> SI.headed "is_anonymous_proxy" boolDecode
        <*> SI.headed "is_satellite_provider" boolDecode
        <*> SI.headed "postal_code" shortTextDecode
        <*> SI.headed "latitude" maybeNumDecode
        <*> SI.headed "longitude" maybeNumDecode
        <*> SI.headed "accuracy_radius" maybeNumDecode
      )

siphonCityBlockV6 :: SI.Siphon Headed B.ByteString (IPv6, IPv6, CityBlock)
siphonCityBlockV6 = (\r cb -> (IPv6.lowerInclusive r,IPv6.upperInclusive r,cb))
  <$> SI.headed "network" ipv6Decode
  <*> ( CityBlock
        <$> SI.headed "geoname_id" maybeNumDecode
        <*> SI.headed "registered_country_geoname_id" maybeNumDecode
        <*> SI.headed "represented_country_geoname_id" maybeNumDecode
        <*> SI.headed "is_anonymous_proxy" boolDecode
        <*> SI.headed "is_satellite_provider" boolDecode
        <*> SI.headed "postal_code" shortTextDecode
        <*> SI.headed "latitude" maybeNumDecode
        <*> SI.headed "longitude" maybeNumDecode
        <*> SI.headed "accuracy_radius" maybeNumDecode
      )

siphonCityLocations :: SI.Siphon Headed B.ByteString (Maybe Int, CityLocation)
siphonCityLocations = (\g cl -> (g,cl))
  <$> SI.headed "geoname_id" numDecode
  <*> ( CityLocation
        <$> SI.headed "locale_code" shortTextDecode
        <*> SI.headed "continent_code" shortTextDecode
        <*> SI.headed "continent_name" shortTextDecode
        <*> SI.headed "country_iso_code" C.decodeUtf8
        <*> SI.headed "country_name" C.decodeUtf8
        <*> SI.headed "subdivision_1_iso_code" shortTextDecode
        <*> SI.headed "subdivision_1_name" shortTextDecode
        <*> SI.headed "subdivision_2_iso_code" shortTextDecode
        <*> SI.headed "subdivision_2_name" shortTextDecode
        <*> SI.headed "city_name" shortTextDecode
        <*> SI.headed "metro_code" shortTextDecode
        <*> SI.headed "time_zone" shortTextDecode
        <*> SI.headed "is_in_european_union" boolDecode
      )

--------------------------------------------------------------------------------

-- Some helper functions for decoding CSVs

intToBool :: Int -> FatBool
intToBool 0 = FatFalse
intToBool 1 = FatTrue
intToBool _ = NotTrueOrFalse

readIntExactly :: B.ByteString -> Maybe Int
readIntExactly bs = do
  (ident,remaining) <- B.readInt bs
  guard (B.null remaining)
  return ident

shortTextDecode :: B.ByteString -> Maybe ShortText
shortTextDecode = TS.fromByteString

numDecode :: B.ByteString -> Maybe (Maybe Int)
numDecode  = Just . readIntExactly

maybeNumDecode :: B.ByteString -> Maybe MaybeInt
maybeNumDecode  = Just . unboxMaybeInt . readIntExactly

boolDecode :: B.ByteString -> Maybe FatBool
boolDecode = fmap intToBool . readIntExactly

ipv4Decode :: B.ByteString -> Maybe IPv4.IPv4Range
ipv4Decode = IPv4.decodeRange <=< either (const Nothing) Just . TE.decodeUtf8'
ipv6Decode :: B.ByteString -> Maybe IPv6.IPv6Range
ipv6Decode = IPv6.decodeRange <=< either (const Nothing) Just . TE.decodeUtf8'

-- | Given a filepath pointing to a CSV,
--   and a 'Siphon' outlining how to consume it,
--   Construct a Stream Of [a].
--   All 'a' values are forced to WHNF.
mkBlock :: (NFData a, Show a) 
  => FilePath 
  -> SI.Siphon Headed B.ByteString a
  -> IO (SR.Of [a] (Maybe SI.SiphonError))
mkBlock path s = IO.withFile path IO.ReadMode
  (\handle -> SR.toList $ SR.mapM (\ a -> evaluate (rnf a) >> pure a) $ SI.decodeCsvUtf8 s (BS.toChunks $ BS.fromHandle handle))

--------------------------------------------------------------------------------

-- | CSV Filepaths.
asnipv4path, asnipv6path, countryipv4path, countryipv6path, 
  cityBlockipv4path, cityBlockipv6path, cityLocationpath, 
  countryLocationpath :: FilePath
asnipv4path         = "./geolite2/asn/GeoLite2-ASN-Blocks-IPv4.csv"
asnipv6path         = "./geolite2/asn/GeoLite2-ASN-Blocks-IPv6.csv"
countryipv4path     = "./geolite2/country/GeoLite2-Country-Blocks-IPv4.csv"
countryipv6path     = "./geolite2/country/GeoLite2-Country-Blocks-IPv6.csv"
cityBlockipv4path   = "./geolite2/city/GeoLite2-City-Blocks-IPv4.csv"
cityBlockipv6path   = "./geolite2/city/GeoLite2-City-Blocks-IPv6.csv"
cityLocationpath    = "./geolite2/city/GeoLite2-City-Locations-en.csv"
countryLocationpath = "./geolite2/country/GeoLite2-Country-Locations-en.csv"

--------------------------------------------------------------------------------

-- | Calls 'mkBlock' on each CSV path, with the 'Siphon'
--   needed to decode it, then returns a value of type
--   'Maps' that it stores inside of a compact region.
mkMaps :: IO Maps
mkMaps = do
  -- Perform CSV decoding 
  ( asnls SR.:> _ )
    <- mkBlock asnipv4path siphonAsn
  ( asnv6ls SR.:> _ )
    <- mkBlock asnipv6path siphonAsnv6
  ( countryls SR.:> _ )
    <- mkBlock countryipv4path siphonCountry
  ( countryv6ls SR.:> _ )
    <- mkBlock countryipv6path siphonCountryV6
  ( cityBlockls SR.:> _ )
    <- mkBlock cityBlockipv4path siphonCityBlock
  ( cityBlockv6ls SR.:> _ )
    <- mkBlock cityBlockipv6path siphonCityBlockV6
  ( cityLocations SR.:> _ )
    <- mkBlock cityLocationpath siphonCityLocations
  ( countryLocations SR.:> _ )
    <- mkBlock countryLocationpath siphonCountryLocations

  -- | Create our various maps.
  let asnipv4diet        :: D.Map IPv4 ASN                     = D.fromList  asnls
      asnipv6diet        :: D.Map IPv6 ASN                     = D.fromList  asnv6ls
      countryipv4diet    :: D.Map IPv4 Country                 = D.fromList  countryls
      countryipv6diet    :: D.Map IPv6 Country                 = D.fromList  countryv6ls
      cityBlockipv4diet  :: D.Map IPv4 CityBlock               = D.fromList  cityBlockls
      cityBlockipv6diet  :: D.Map IPv6 CityBlock               = D.fromList  cityBlockv6ls
      cityLocationMap    :: MS.Map (Maybe Int) CityLocation    = MS.fromList cityLocations
      countryLocationMap :: MS.Map (Maybe Int) CountryLocation = MS.fromList countryLocations

  -- | Construct a 'Maps' and store it inside of a compact
  --   region. This is advantageous because our data does
  --   not (and does not need to) take advantage of sharing.
  x <- compact (Maps asnipv4diet asnipv6diet countryipv4diet
        countryipv6diet cityBlockipv4diet cityBlockipv6diet
        cityLocationMap countryLocationMap)
  pure (getCompact x)

--------------------------------------------------------------------------------

-- | Unzip the three CSVs. This should probably
--   be implemented in a way that is more amenable
--   to API change.
unzipCsvs :: Archive -> Archive -> Archive -> IO ()
unzipCsvs asnZip cityZip countryZip = do
  let zipPath :: FilePath
      zipPath = "./geolite2/"
  extractFilesFromArchive [ OptRecursive, OptDestination $ zipPath ] asnZip
  extractFilesFromArchive [ OptRecursive, OptDestination $ zipPath ] cityZip
  extractFilesFromArchive [ OptRecursive, OptDestination $ zipPath ] countryZip

-- | Download a single CSV
download :: FilePath -> IO B.ByteString
download dlurl = runReq def $ do
  let (url, _) = fromJust (parseUrlHttps $ B.pack dlurl)
  response <- req GET url NoReqBody bsResponse mempty
  pure (responseBody response)

-- | Download all three CSVs. This should probably be
--   implemented in a way that is more amenable to API
--   change.
downloadCsvs :: IO (B.ByteString, B.ByteString, B.ByteString)
downloadCsvs = do
  cityZip    <- download "https://geolite.maxmind.com/download/geoip/database/GeoLite2-City-CSV.zip"
  countryZip <- download "https://geolite.maxmind.com/download/geoip/database/GeoLite2-Country-CSV.zip"
  asnZip     <- download "https://geolite.maxmind.com/download/geoip/database/GeoLite2-ASN-CSV.zip"
  pure (cityZip, countryZip, asnZip)

-- | Deletes everything in the CSVs folder.
removeCsvs :: IO ()
removeCsvs = do
  dirs <- listDirectory "./geolite2"
  mapM_ removeDirectoryRecursive ( map ((<>) "./geolite2/") dirs )

-- | Rename everything in
renameDirs :: [FilePath] -> IO ()
renameDirs xs
  | length xs == 3 = do
      renameDirectory ( csvDir <> (xs !! 0) ) ( csvDir <> "country/" )
      renameDirectory ( csvDir <> (xs !! 1) ) ( csvDir <> "asn/"     )
      renameDirectory ( csvDir <> (xs !! 2) ) ( csvDir <> "city/" )
  | otherwise = error "Superfluous files in ./geolite2/, or there was possibly an api change"

-- | The directory in which the CSVs should live.
csvDir :: String
csvDir = "./geolite2/"

-- | Re-organize the CSVs in 'csvDir'.
organizeCsvs :: IO ()
organizeCsvs = listDirectory csvDir >>= renameDirs

--------------------------------------------------------------------------------

-- | 'getCsvs' does the following:
--
--   1. removes all CSVs in 'csvDir';
--   2. Downloads all the new, zipped CSVs;
--   3. Unzips the CSVs;
--   4. Makes sure they are well-formatted, and;
--   5. Constructs the 'Maps' we need for the
--      API to run.
getCsvs :: IO Maps
getCsvs = do
  removeCsvs
  (cityZip, countryZip, asnZip) <- downloadCsvs
  unzipCsvs  ( toArchive $ fromStrict asnZip     )
             ( toArchive $ fromStrict cityZip    )
             ( toArchive $ fromStrict countryZip )
  organizeCsvs
  mkMaps

-- | 'replaceCsvs' reloads the CSVs into
--   an 'IORef' used by the server to make
--   sure we are referencing the newest data.
--   It then forces a major GC to make sure
--   there is no unnecessary space utilisation.
replaceCsvs :: IORef Maps -> IO ()
replaceCsvs imaps = do
  T.putStrLn "Reloading geolite2 data..."
  getCsvs >>= writeIORef imaps
  performMajorGC
