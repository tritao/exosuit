import {pathToFileURL} from 'node:url';
const {renameSession} = await import(pathToFileURL(process.argv[2]).href);
await renameSession(process.argv[3], process.argv[5], {dir: process.argv[4]});
