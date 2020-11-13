{-# LANGUAGE CPP #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeApplications #-}
-- | @multipart/form-data@ support for servant.
--
--   This is mostly useful for adding file upload support to
--   an API. See haddocks of 'MultipartForm' for an introduction.
module Servant.Multipart.API
  ( MultipartForm
  , MultipartForm'
  , MultipartData(..)
  , ToMultipart(..)
  , FromMultipart(..)
  , lookupInput
  , lookupFile
  , MultipartBackend(..)
  , Tmp
  , Mem
  , Input(..)
  , FileData(..)
  ) where

import Control.Lens ((<>~), (&), view, (.~))
import Control.Monad (replicateM)
import Control.Monad.IO.Class
import Control.Monad.Trans.Resource
import Data.Array (listArray, (!))
import Data.List (find, foldl')
import Data.Maybe
import Data.Monoid
import Data.String.Conversions (cs)
import Data.Text (Text, unpack)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Typeable
import Network.HTTP.Media.MediaType ((//), (/:))
import Servant.API
import Servant.API.Modifiers (FoldLenient)
import Servant.Types.SourceT (SourceT(..), source, StepT(..), fromActionStep)
import System.Directory
import System.IO (IOMode(ReadMode), withFile)
import System.Random (getStdRandom, Random(randomR))

import qualified Data.ByteString      as SBS
import qualified Data.ByteString.Lazy as LBS

-- | Combinator for specifying a @multipart/form-data@ request
--   body, typically (but not always) issued from an HTML @\<form\>@.
--
--   @multipart/form-data@ can't be made into an ordinary content
--   type for now in servant because it doesn't just decode the
--   request body from some format but also performs IO in the case
--   of writing the uploaded files to disk, e.g in @/tmp@, which is
--   not compatible with servant's vision of a content type as things
--   stand now. This also means that 'MultipartForm' can't be used in
--   conjunction with 'ReqBody' in an endpoint.
--
--   The 'tag' type parameter instructs the function to handle data
--   either as data to be saved to temporary storage ('Tmp') or saved to
--   memory ('Mem').
--
--   The 'a' type parameter represents the Haskell type to which
--   you are going to decode the multipart data to, where the
--   multipart data consists in all the usual form inputs along
--   with the files sent along through @\<input type="file"\>@
--   fields in the form.
--
--   One option provided out of the box by this library is to decode
--   to 'MultipartData'.
--
--   Example:
--
--   @
--   type API = MultipartForm Tmp (MultipartData Tmp) :> Post '[PlainText] String
--
--   api :: Proxy API
--   api = Proxy
--
--   server :: MultipartData Tmp -> Handler String
--   server multipartData = return str
--
--     where str = "The form was submitted with "
--              ++ show nInputs ++ " textual inputs and "
--              ++ show nFiles  ++ " files."
--           nInputs = length (inputs multipartData)
--           nFiles  = length (files multipartData)
--   @
--
--   You can alternatively provide a 'FromMultipart' instance
--   for some type of yours, allowing you to regroup data
--   into a structured form and potentially selecting
--   a subset of the entire form data that was submitted.
--
--   Example, where we only look extract one input, /username/,
--   and one file, where the corresponding input field's /name/
--   attribute was set to /pic/:
--
--   @
--   data User = User { username :: Text, pic :: FilePath }
--
--   instance FromMultipart Tmp User where
--     fromMultipart multipartData =
--       User \<$\> lookupInput "username" multipartData
--            \<*\> fmap fdPayload (lookupFile "pic" multipartData)
--
--   type API = MultipartForm Tmp User :> Post '[PlainText] String
--
--   server :: User -> Handler String
--   server usr = return str
--
--     where str = username usr ++ "'s profile picture"
--              ++ " got temporarily uploaded to "
--              ++ pic usr ++ " and will be removed from there "
--              ++ " after this handler has run."
--   @
--
--   Note that the behavior of this combinator is configurable,
--   by using 'serveWith' from servant-server instead of 'serve',
--   which takes an additional 'Context' argument. It simply is an
--   heterogeneous list where you can for example store
--   a value of type 'MultipartOptions' that has the configuration that
--   you want, which would then get picked up by servant-multipart.
--
--   __Important__: as mentionned in the example above,
--   the file paths point to temporary files which get removed
--   after your handler has run, if they are still there. It is
--   therefore recommended to move or copy them somewhere in your
--   handler code if you need to keep the content around.
type MultipartForm tag a = MultipartForm' '[] tag a

-- | 'MultipartForm' which can be modified with 'Servant.API.Modifiers.Lenient'.
data MultipartForm' (mods :: [*]) tag a

-- | What servant gets out of a @multipart/form-data@ form submission.
--
--   The type parameter 'tag' tells if 'MultipartData' is stored as a
--   temporary file or stored in memory. 'tag' is type of either 'Mem'
--   or 'Tmp'.
--
--   The 'inputs' field contains a list of textual 'Input's, where
--   each input for which a value is provided gets to be in this list,
--   represented by the input name and the input value. See haddocks for
--   'Input'.
--
--   The 'files' field contains a list of files that were sent along with the
--   other inputs in the form. Each file is represented by a value of type
--   'FileData' which among other things contains the path to the temporary file
--   (to be removed when your handler is done running) with a given uploaded
--   file's content. See haddocks for 'FileData'.
data MultipartData tag = MultipartData
  { inputs :: [Input]
  , files  :: [FileData tag]
  }

-- | Representation for an uploaded file, usually resulting from
--   picking a local file for an HTML input that looks like
--   @\<input type="file" name="somefile" /\>@.
data FileData tag = FileData
  { fdInputName :: Text     -- ^ @name@ attribute of the corresponding
                            --   HTML @\<input\>@
  , fdFileName  :: Text     -- ^ name of the file on the client's disk
  , fdFileCType :: Text     -- ^ MIME type for the file
  , fdPayload   :: MultipartResult tag
                            -- ^ path to the temporary file that has the
                            --   content of the user's original file. Only
                            --   valid during the execution of your handler as
                            --   it gets removed right after, which means you
                            --   really want to move or copy it in your handler.
  }

deriving instance Eq (MultipartResult tag) => Eq (FileData tag)
deriving instance Show (MultipartResult tag) => Show (FileData tag)

-- | Lookup a file input with the given @name@ attribute.
lookupFile :: Text -> MultipartData tag -> Either String (FileData tag)
lookupFile iname =
  maybe (Left $ "File " <> cs iname <> " not found") Right
  . find ((==iname) . fdInputName)
  . files

-- | Representation for a textual input (any @\<input\>@ type but @file@).
--
--   @\<input name="foo" value="bar"\ />@ would appear as @'Input' "foo" "bar"@.
data Input = Input
  { iName  :: Text -- ^ @name@ attribute of the input
  , iValue :: Text -- ^ value given for that input
  } deriving (Eq, Show)

-- | Lookup a textual input with the given @name@ attribute.
lookupInput :: Text -> MultipartData tag -> Either String Text
lookupInput iname =
  maybe (Left $ "Field " <> cs iname <> " not found") (Right . iValue)
  . find ((==iname) . iName)
  . inputs

-- | 'MultipartData' is the type representing
--   @multipart/form-data@ form inputs. Sometimes
--   you may instead want to work with a more structured type
--   of yours that potentially selects only a fraction of
--   the data that was submitted, or just reshapes it to make
--   it easier to work with. The 'FromMultipart' class is exactly
--   what allows you to tell servant how to turn "raw" multipart
--   data into a value of your nicer type.
--
--   @
--   data User = User { username :: Text, pic :: FilePath }
--
--   instance FromMultipart Tmp User where
--     fromMultipart form =
--       User \<$\> lookupInput "username" (inputs form)
--            \<*\> fmap fdPayload (lookupFile "pic" $ files form)
--   @
class FromMultipart tag a where
  -- | Given a value of type 'MultipartData', which consists
  --   in a list of textual inputs and another list for
  --   files, try to extract a value of type @a@. When
  --   extraction fails, servant errors out with status code 400.
  fromMultipart :: MultipartData tag -> Either String a

instance FromMultipart tag (MultipartData tag) where
  fromMultipart = Right

-- | Allows you to tell servant how to turn a more structured type
--   into a 'MultipartData', which is what is actually sent by the
--   client.
--
--   @
--   data User = User { username :: Text, pic :: FilePath }
--
--   instance toMultipart Tmp User where
--       toMultipart user = MultipartData [Input "username" $ username user]
--                                        [FileData "pic"
--                                                  (pic user)
--                                                  "image/png"
--                                                  (pic user)
--                                        ]
--   @
class ToMultipart tag a where
  -- | Given a value of type 'a', convert it to a
  -- 'MultipartData'.
  toMultipart :: a -> MultipartData tag

instance ToMultipart tag (MultipartData tag) where
  toMultipart = id

-- | Generates a boundary to be used to separate parts of the multipart.
-- Requires 'IO' because it is randomized.
genBoundary :: IO LBS.ByteString
genBoundary = LBS.pack
            . map (validChars !)
            <$> indices
  where
    -- the standard allows up to 70 chars, but most implementations seem to be
    -- in the range of 40-60, so we pick 55
    indices = replicateM 55 . getStdRandom $ randomR (0,61)
    -- Following Chromium on this one:
    -- > The RFC 2046 spec says the alphanumeric characters plus the
    -- > following characters are legal for boundaries:  '()+_,-./:=?
    -- > However the following characters, though legal, cause some sites
    -- > to fail: (),./:=+
    -- https://github.com/chromium/chromium/blob/6efa1184771ace08f3e2162b0255c93526d1750d/net/base/mime_util.cc#L662-L670
    validChars = listArray (0 :: Int, 61)
                           -- 0-9
                           [ 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37
                           , 0x38, 0x39, 0x41, 0x42
                           -- A-Z, a-z
                           , 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a
                           , 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x51, 0x52
                           , 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a
                           , 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68
                           , 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70
                           , 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78
                           , 0x79, 0x7a
                           ]

class MultipartBackend tag where
    type MultipartResult tag :: *
    type MultipartBackendOptions tag :: *

    backend :: Proxy tag
            -> MultipartBackendOptions tag
            -> InternalState
            -> ignored1
            -> ignored2
            -> IO SBS.ByteString
            -> IO (MultipartResult tag)

    loadFile :: Proxy tag -> MultipartResult tag -> SourceIO LBS.ByteString

    defaultBackendOptions :: Proxy tag -> MultipartBackendOptions tag

-- | Tag for data stored as a temporary file
data Tmp

-- | Tag for data stored in memory
data Mem

instance HasLink sub => HasLink (MultipartForm tag a :> sub) where
#if MIN_VERSION_servant(0,14,0)
  type MkLink (MultipartForm tag a :> sub) r = MkLink sub r
  toLink toA _ = toLink toA (Proxy :: Proxy sub)
#else
  type MkLink (MultipartForm tag a :> sub) = MkLink sub
  toLink _ = toLink (Proxy :: Proxy sub)
#endif
