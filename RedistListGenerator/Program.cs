/*
 * Copyright 2019 Stanislav Muhametsin. All rights Reserved.
 *
 * Licensed  under the  Apache License,  Version 2.0  (the "License");
 * you may not use  this file  except in  compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed  under the  License is distributed on an "AS IS" BASIS,
 * WITHOUT  WARRANTIES OR CONDITIONS  OF ANY KIND, either  express  or
 * implied.
 *
 * See the License for the specific language governing permissions and
 * limitations under the License. 
 */
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Xml.Linq;

namespace RedistListGenerator
{
   static class Program
   {
      // First arg - RedisList files base dir
      // Second arg - all possible .NET Desktop frameworks
      // Third arg - values of FrameworkPathOverride-properties for each framework, in same order as third arg
      public static void Main( String[] args )
      {
         var baseDir = args[0];
         var tfList = args[1];
         var targetFrameworks = tfList.Split( ';', StringSplitOptions.RemoveEmptyEntries );
         if ( targetFrameworks.Length > 0 )
         {
            var fpoList = args[2].Split( ';', StringSplitOptions.RemoveEmptyEntries );
            foreach ( var info in targetFrameworks
               .Select( ( tfw, idx ) => (tfw, fpoList[idx], Path.Combine( baseDir, tfw, "FrameworkList.xml" )) )
               .Where( tfw => !File.Exists( tfw.Item3 ) && Directory.Exists( tfw.Item2 ) )
               )
            {
               (var tfw, var fpo, var path) = info;
               if ( !Path.IsPathRooted( fpo ) )
               {
                  throw new Exception( $"Unrooted FPO: {fpo}." );
               }
               var xDoc = new XDocument(
                  new XDeclaration( "1.0", "utf-8", null ),
                  GenerateFileListElement( Path.GetFullPath( fpo ), tfw )
                  );

               var targetDir = Path.GetDirectoryName( path );
               if ( !Directory.Exists( targetDir ) )
               {
                  Directory.CreateDirectory( targetDir );
               }

               xDoc.Save( path );
            }
         }
      }

      private static XElement GenerateFileListElement(
         String assembliesDirectory,
         String targetFramework
         )
      {
         return new XElement( "FileList",
            Directory.EnumerateFiles( assembliesDirectory, "*.dll", SearchOption.TopDirectoryOnly )
               .OrderBy( assemblyPath => Path.GetFileNameWithoutExtension( assemblyPath ) )
               .Select( assemblyPath => (Object) GenerateFileElement( assemblyPath ) )
               .Where( o => o != null )
               .Prepend( new XAttribute( "Redist", "Microsoft-Windows-CLRCoreComp." + String.Join( '.', targetFramework.SkipWhile( c => !Char.IsDigit( c ) ).Select( c => c.ToString() ) ) ) ) // e.g. net46 -> 4.6
            );
      }

      private static XElement GenerateFileElement(
         String assemblyPath
         )
      {
         XElement retVal = null;
         using ( var stream = File.Open( assemblyPath, FileMode.Open, FileAccess.Read, FileShare.Read ) )
         {
            using ( var reader = new PEReader( stream, PEStreamOptions.LeaveOpen ) )
            {
               MetadataReader mdReader = null;
               try
               {
                  mdReader = reader.GetMetadataReader( MetadataReaderOptions.None );
               }
               catch ( InvalidOperationException )
               {
                  // Sometimes the DLL file is not managed, and that's ok
               }

               if ( mdReader != null && mdReader.IsAssembly )
               {
                  var assembly = mdReader.GetAssemblyDefinition();
                  retVal = new XElement( "File",
                     new XAttribute( "AssemblyName", mdReader.GetString( assembly.Name ) ),
                     new XAttribute( "Version", assembly.Version ),
                     new XAttribute( "PublicKeyToken", String.Join( "", mdReader.GetBlobBytes( assembly.PublicKey ).PublicKeyTokenFromPublicKey().Select( b => String.Format( "{0:x2}", b ) ) ) ),
                     new XAttribute( "Culture", mdReader.GetString( assembly.Culture ).DefaultIfNullOrEmpty( "neutral" ) ),
                     new XAttribute( "ProcessorArchitecture", "MSIL" ),
                     new XAttribute( "InGac", "true" )
                     );
                  if ( assembly.Flags.HasFlag( System.Reflection.AssemblyFlags.Retargetable ) )
                  {
                     // This does not seem to be in actual use (yet) by ResolveAssemblyReferences task at least.
                     retVal.Add( new XAttribute( "Retargetable", "true" ) );
                  }

                  // There is also some IsRedistRoot attribute but I am not sure of its full meaning
               }
            }
         }

         return retVal;
      }

      private static Byte[] PublicKeyTokenFromPublicKey( this Byte[] publicKey )
      {
         using ( var sha = SHA1.Create() )
         {
            // Public key token = reversed last 8 bytes of SHA1 of the full public key.
            var token = sha.ComputeHash( publicKey ).TakeLast( 8 ).ToArray();
            Array.Reverse( token );
            return token;
         }
      }

      private static String DefaultIfNullOrEmpty( this String str, String defaultValue )
      {
         return String.IsNullOrEmpty( str ) ? defaultValue : str;
      }

   }
}
