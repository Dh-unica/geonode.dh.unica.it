
from django.core.management.base import BaseCommand
from geonode.maps.models import Map, MapLayer
from geonode.layers.models import Dataset
from collections import namedtuple

obj = namedtuple("LayerObj", field_names=['id', 'name', 'style', 'opacity', 'visibility'])


class Command(BaseCommand):
    help = "Fix the missing Maplayers for the MAPS"

    def handle(self, **options):
        for _map in Map.objects.iterator():
            #getting the blob
            _blob = _map.blob
            layers = []
            print(f"Extracting layer from map: {_map}")
            for item in _blob['map']['layers']:
                if item.get('group') !='background':
                    match item['type']:
                        case 'wms':
                            layers.append(obj(item['id'], item['name'], item.get('styles'), item.get("opacity", 1), item.get("visibility", True)))
                        case _:
                            pass
            print(f"Layers found ({len(layers)})")
            
            print("start generation of maplayers for the selected map")
            maplayers_id = []
            for layer in layers:
                # getting layer informationms
                dataset = Dataset.objects.filter(alternate=layer.name).first()
                if not dataset:
                    print(f"ERROR: cannot find dataset named: {layer.name}")
                
                if not MapLayer.objects.filter(map=_map, dataset=dataset).exists():
                    maplayer = MapLayer.objects.create(
                        map=_map,
                        dataset=dataset,
                        extra_params={
                            "msId": layer.id
                        },
                        name=dataset.alternate,
                        current_style=(layer.style[0].get("name") if layer.style else None) or (dataset.default_style.name if dataset.default_style else None),
                        opacity=layer.opacity,
                        visibility=layer.visibility
                    )
                    maplayers_id.append({layer.id: maplayer.pk})
            print("Maplayer created")
            if maplayers_id:
                print("Update map blob with extendedParams")
                layers_blob = []
                for item in _blob['map']['layers']:
                    exists = [x for x in maplayers_id if x.get(item['id'])]
                    if exists:
                        item.update({"extendedParams": {"pk": exists[0].get(item['id'])}})
                        layers_blob.append(item)
                print("Updating map blob")
                _new_blob = _blob.copy()
                _new_blob['map']['layers'] = layers_blob
                _map.blob = _new_blob
                _map.save()

        print("Maplayer generation completed")
