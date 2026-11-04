import { type EnrichedObjectMetadataItem } from '@/object-metadata/types/EnrichedObjectMetadataItem';
import { type ObjectPermissions } from 'twenty-shared/types';
import { isDefined } from 'twenty-shared/utils';

type IsObjectMetadataReadOnlyParams = {
  objectPermissions?: Pick<ObjectPermissions, 'canUpdateObjectRecords'>;
  objectMetadataItem?: Pick<
    EnrichedObjectMetadataItem,
    'isUIEditable' | 'isRemote'
  >;
};

export const isObjectMetadataReadOnly = ({
  objectPermissions,
  objectMetadataItem,
}: IsObjectMetadataReadOnlyParams) => {
  const isReadOnlyForUser =
    isDefined(objectPermissions) && !objectPermissions.canUpdateObjectRecords;

  const isReadOnlyObject =
    isDefined(objectMetadataItem) &&
    (objectMetadataItem.isUIEditable || objectMetadataItem.isRemote);

  return isReadOnlyForUser || isReadOnlyObject;
};
