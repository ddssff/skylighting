{-# LANGUAGE CPP  #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Skylighting.Regex (
                Regex
              , RegexException
              , RE(..)
              , compileRegex
              , matchRegex
              , convertOctalEscapes
              ) where

import qualified Control.Exception as E
import Data.Aeson
import Data.Binary (Binary)
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Char8 as BS
import Data.ByteString.UTF8 (toString)
import Data.Data
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)
import Text.Printf
#if __GHCJS__
import Text.Regex.TDFA
import Text.Regex.TDFA.ByteString
#else
import System.IO.Unsafe (unsafePerformIO)
import Text.Regex.PCRE.ByteString
#endif

-- | An exception in compiling or executing a regex.
newtype RegexException = RegexException String
      deriving (Show, Typeable, Generic)

instance E.Exception RegexException

-- | A representation of a regular expression.
data RE = RE{
    reString        :: BS.ByteString
  , reCaseSensitive :: Bool
} deriving (Show, Read, Ord, Eq, Data, Typeable, Generic)

instance Binary RE

instance ToJSON RE where
  toJSON re = object [ "reString"        .= encodeToText (reString re)
                     , "reCaseSensitive" .= reCaseSensitive re ]
instance FromJSON RE where
  parseJSON = withObject "RE" $ \v ->
    RE <$> ((v .: "reString") >>= decodeFromText)
       <*> v .: "reCaseSensitive"

-- | Compile a PCRE regex.  If the first parameter is True, the regex is
-- case-sensitive, otherwise caseless.  The regex is compiled from
-- a bytestring interpreted as UTF-8.  If the regex cannot be compiled,
-- a 'RegexException' is thrown.
compileRegex :: Bool -> BS.ByteString -> Regex
#if __GHCJS
compileRegex caseSensitive' regexpStr =
  let opts = {-compAnchored + compUTF8 +-}
               (defaultCompOpt {caseSensitive = caseSensitive'})
  in  case {-unsafePerformIO $-} compile opts ({-execNotEmpty-} defaultExecOpt) regexpStr of
            Left ({-off,-}msg) -> E.throw $ RegexException $
                        "Error compiling regex /" ++ toString regexpStr ++
                        "/ " ++ {-"at offset " ++ show off ++-} "\n" ++ msg
            Right r -> r
#else
compileRegex caseSensitive regexpStr =
  let opts = compAnchored + compUTF8 +
               if caseSensitive then 0 else compCaseless
  in  case unsafePerformIO $ compile opts (execNotEmpty) regexpStr of
            Left (off,msg) -> E.throw $ RegexException $
                        "Error compiling regex /" ++ toString regexpStr ++
                        "/ at offset " ++ show off ++ "\n" ++ msg
            Right r -> r
#endif

-- | Convert octal escapes to the form pcre wants.  Note:
-- need at least pcre 8.34 for the form \o{dddd}.
-- So we prefer \ddd or \x{...}.
convertOctalEscapes :: String -> String
convertOctalEscapes [] = ""
convertOctalEscapes ('\\':'0':x:y:z:rest)
  | all isOctalDigit [x,y,z] = '\\':x:y:z: convertOctalEscapes rest
convertOctalEscapes ('\\':x:y:z:rest)
  | all isOctalDigit [x,y,z] ='\\':x:y:z: convertOctalEscapes rest
convertOctalEscapes ('\\':'o':'{':zs) =
  case break (=='}') zs of
       (ds, '}':rest) | all isOctalDigit ds && not (null ds) ->
            case reads ('0':'o':ds) of
                 ((n :: Int,[]):_) ->
                     printf "\\x{%x}" n ++ convertOctalEscapes rest
                 _          -> E.throw $ RegexException $
                                   "Unable to read octal number: " ++ ds
       _  -> '\\':'o':'{': convertOctalEscapes zs
convertOctalEscapes (x:xs) = x : convertOctalEscapes xs

isOctalDigit :: Char -> Bool
isOctalDigit c = c >= '0' && c <= '7'

-- | Match a 'Regex' against a bytestring.  Returns 'Nothing' if
-- no match, otherwise 'Just' a nonempty list of bytestrings. The first
-- bytestring in the list is the match, the others the captures, if any.
-- If there are errors in executing the regex, a 'RegexException' is
-- thrown.
matchRegex :: Regex -> BS.ByteString -> Maybe [BS.ByteString]
#if __GHCJS__
matchRegex r s = case (regexec r s) of
                      Right (Just (_, mat, _ , capts)) ->
                                       Just (mat : capts)
                      Right Nothing -> Nothing
                      Left (msg) -> E.throw $ RegexException msg
#else
matchRegex r s = case unsafePerformIO (regexec r s) of
                      Right (Just (_, mat, _ , capts)) ->
                                       Just (mat : capts)
                      Right Nothing -> Nothing
                      Left (_rc, msg) -> E.throw $ RegexException msg
#endif

-- functions to marshall bytestrings to text

encodeToText :: BS.ByteString -> Text.Text
encodeToText = TE.decodeUtf8 . Base64.encode

decodeFromText :: (Monad m) => Text.Text -> m BS.ByteString
decodeFromText = either fail return . Base64.decode . TE.encodeUtf8
